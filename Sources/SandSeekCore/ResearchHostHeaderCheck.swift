import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// "Does the model server look at the HTTP Host header?"
//
// A web page in your browser can use DNS rebinding: its own host name is made
// to resolve to 127.0.0.1, so the browser sends requests for it to a server on
// this Mac, with a `Host:` header that names the page's host. A server that
// refuses a Host it does not know (400, 403 or 421) gets nothing from such a
// page. A server that answers as usual does, unless it asks for a key that the
// page does not have.
//
// The check sends plain HTTP/1.1 requests over a TCP socket to 127.0.0.1,
// because URLSession does not reliably let a program choose the Host header.
// Only GET requests go out, to one read-only path, and never a prompt:
//   1. the normal Host (the control),
//   2. a Host that never resolves (`sandseek-host-check.invalid`),
//   3. the normal Host with a foreign `Origin` (to see the CORS answer),
//   and, when a key is sent, a fourth request without it, to see whether the
//   server enforces the key.
// Each answer is read up to its status line and headers (at most 16 KiB, with
// a time limit); the body is never looked at. A key is sent only in the
// `Authorization` header and is never printed or logged.

// MARK: - Answers

/// What one probe request came to.
public enum ResearchProbeAnswer: Equatable, Sendable {
    /// A status line was read. Header names are lower-case.
    case status(code: Int, headers: [String: String])
    /// No answer: the connection was refused, timed out, was closed without a
    /// status line, or the reply was not HTTP.
    case noAnswer

    /// The status code, or nil for `.noAnswer`.
    public var statusCode: Int? {
        if case .status(let code, _) = self { return code }
        return nil
    }

    /// `HTTP 403`, or `no answer`.
    public var text: String {
        if let code = statusCode { return "HTTP \(code)" }
        return "no answer"
    }
}

/// Sends one GET request with chosen headers to a server on this Mac. A fake
/// stands in for it in tests.
public protocol ResearchHTTPProbing: Sendable {
    /// `GET <path> HTTP/1.1` to `port` with `Host: <host>`, an optional
    /// `Origin` and an optional `Authorization` (the full header value). Waits
    /// up to `timeout` seconds in all. Never throws: every failure is
    /// `.noAnswer`.
    func get(port: Int, path: String, host: String, origin: String?, authorization: String?,
             timeout: TimeInterval) async -> ResearchProbeAnswer
}

// MARK: - The request and the reply, as bytes

public enum ResearchHostHeaderRequest {
    /// The most bytes read from a reply. Only the status line and the headers
    /// matter.
    public static let maxResponseBytes = 16 * 1024

    public static let userAgent = "SandSeek host check"

    /// True for a non-empty value of printable ASCII only. Anything else,
    /// above all CR and LF, could end the header line and add another one.
    public static func isSafeHeaderValue(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7f }
    }

    /// The request as bytes, or nil when a value is not safe or the path is
    /// not a plain path (it must start with `/` and have no space).
    public static func build(path: String, host: String, origin: String?,
                             authorization: String?) -> [UInt8]? {
        guard isSafeHeaderValue(path), path.hasPrefix("/"), !path.contains(" "),
              isSafeHeaderValue(host) else { return nil }
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "User-Agent: \(userAgent)",
            "Accept: */*",
            "Connection: close",
        ]
        if let origin {
            guard isSafeHeaderValue(origin) else { return nil }
            lines.append("Origin: \(origin)")
        }
        if let authorization {
            guard isSafeHeaderValue(authorization) else { return nil }
            lines.append("Authorization: \(authorization)")
        }
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// True once `bytes` holds the empty line that ends the headers.
    static func hasEndOfHeaders(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 0x0A {
                if bytes[index + 1] == 0x0A { return true }
                if bytes[index + 1] == 0x0D, index + 2 < bytes.count, bytes[index + 2] == 0x0A {
                    return true
                }
            }
            index += 1
        }
        return false
    }

    /// The status and headers of a reply read so far. A line that is not
    /// finished yet is ignored. `.noAnswer` unless the first line is an
    /// `HTTP/1.x` status line with a three-digit code.
    public static func parse(_ bytes: [UInt8]) -> ResearchProbeAnswer {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == 0x0A {
                if current.last == 0x0D { current.removeLast() }
                lines.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        guard let first = lines.first else { return .noAnswer }
        let statusLine = String(decoding: first, as: UTF8.self)
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3,
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let code = Int(parts[1]), (100...599).contains(code) else {
            return .noAnswer
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let text = String(decoding: line, as: UTF8.self)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return .status(code: code, headers: headers)
    }
}

// MARK: - The real prober

/// The real thing: a POSIX TCP socket to a loopback address, set to
/// non-blocking, with `poll` and one deadline for connecting, sending and
/// reading. It runs on a dispatch queue so that it never blocks one of the
/// threads Swift concurrency uses.
public struct ResearchSocketHTTPProber: ResearchHTTPProbing {
    /// Where to connect. Only a loopback address makes sense; the command
    /// refuses anything else before it gets here.
    public let address: ResearchHostAddress

    public init(address: ResearchHostAddress = .ipv4(127, 0, 0, 1)) {
        self.address = address
    }

    public func get(port: Int, path: String, host: String, origin: String?,
                    authorization: String?, timeout: TimeInterval) async -> ResearchProbeAnswer {
        guard let request = ResearchHostHeaderRequest.build(
            path: path, host: host, origin: origin, authorization: authorization) else {
            return .noAnswer
        }
        let bytes = address.bytes
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<ResearchProbeAnswer, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.exchange(
                    address: bytes, port: port, request: request, timeout: timeout))
            }
        }
    }

    /// Milliseconds left until `deadline` (0 when it has passed).
    private static func remaining(until deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline { return 0 }
        return Int32(min((deadline - now) / 1_000_000, 60_000))
    }

    /// Starts a connect on the non-blocking `descriptor`.
    private static func startConnect(descriptor: Int32, bytes: [UInt8], port: UInt16) -> Int32 {
        if bytes.count == 16 {
            var socketAddress = sockaddr_in6()
            #if canImport(Darwin)
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = port.bigEndian
            withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { $0.copyBytes(from: bytes) }
            return withUnsafePointer(to: socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        var socketAddress = sockaddr_in()
        #if canImport(Darwin)
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func exchange(address bytes: [UInt8], port: Int, request: [UInt8],
                                 timeout: TimeInterval) -> ResearchProbeAnswer {
        guard let portNumber = UInt16(exactly: port), portNumber != 0 else { return .noAnswer }
        guard bytes.count == 4 || bytes.count == 16 else { return .noAnswer }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(min(max(timeout, 0.05), 60) * 1_000_000_000)
        // Glibc imports SOCK_STREAM as an enum with a raw value; macOS and
        // musl import it as an integer.
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(bytes.count == 16 ? AF_INET6 : AF_INET, streamType, 0)
        guard descriptor >= 0 else { return .noAnswer }
        defer { close(descriptor) }
        // A write to a connection the server already closed must not end the
        // process with SIGPIPE: macOS has a socket option for that, Linux a
        // flag on every send.
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))
        let sendFlags: Int32 = 0
        #else
        let sendFlags = Int32(MSG_NOSIGNAL)
        #endif
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return .noAnswer
        }

        // Connect.
        let started = startConnect(descriptor: descriptor, bytes: bytes, port: portNumber)
        let connectError = errno
        if started != 0 {
            guard connectError == EINPROGRESS else { return .noAnswer }
            var connecting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            var ready: Int32 = -1
            for _ in 0..<3 {
                ready = poll(&connecting, 1, remaining(until: deadline))
                if ready >= 0 || errno != EINTR { break }
            }
            guard ready > 0 else { return .noAnswer }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0,
                  failure == 0 else { return .noAnswer }
        }

        // Send.
        var sent = 0
        while sent < request.count {
            let wait = remaining(until: deadline)
            if wait == 0 { return .noAnswer }
            let wrote = request[sent...].withUnsafeBytes { raw in
                send(descriptor, raw.baseAddress, raw.count, sendFlags)
            }
            if wrote > 0 {
                sent += wrote
            } else if wrote < 0, errno == EINTR {
                continue
            } else if wrote < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&writable, 1, wait)
            } else {
                return .noAnswer
            }
        }

        // Read the status line and the headers, no more than the cap.
        let cap = ResearchHostHeaderRequest.maxResponseBytes
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while received.count < cap {
            if ResearchHostHeaderRequest.hasEndOfHeaders(received) { break }
            let wait = remaining(until: deadline)
            if wait == 0 { break }
            var readable = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readable, 1, wait)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }
            let count = chunk.withUnsafeMutableBytes { raw in
                recv(descriptor, raw.baseAddress, raw.count, 0)
            }
            if count > 0 {
                received.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            break
        }
        if received.count > cap { received.removeLast(received.count - cap) }
        return ResearchHostHeaderRequest.parse(received)
    }
}

// MARK: - The report

/// What the check found for one port. It holds the answers and works the
/// verdict out from them, so that a test can try every combination.
public struct ResearchHostHeaderReport: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// The server refuses a request that names another host (or closes
        /// the connection): rebinding gets nothing.
        case checksHost
        /// The server answers a request that names another host.
        case acceptsAnyHost
        /// No key was sent and the server asked for one (401 or 403), so a
        /// rebinding page, which has none, gets nothing either.
        case keyRequired
        /// The normal request got no answer at all: cannot tell.
        case serverNotRunning
        /// Anything else (a 5xx, a 404, a refused key, odd combinations).
        case unclear
    }

    public let port: Int
    /// The path that was asked.
    public let path: String
    /// Whether the first, second and third request carried an `Authorization`.
    public let keySent: Bool
    /// Probe 1: the normal Host (with the key, when one was sent).
    public let control: ResearchProbeAnswer
    /// Probe 2: the foreign Host. Nil when it was not sent.
    public let foreignHost: ResearchProbeAnswer?
    /// Probe 3: the normal Host and a foreign Origin. Nil when not sent.
    public let foreignOrigin: ResearchProbeAnswer?
    /// Extra probe: the normal Host without the key. Nil unless a key was sent.
    public let withoutKey: ResearchProbeAnswer?

    public init(port: Int, path: String, keySent: Bool, control: ResearchProbeAnswer,
                foreignHost: ResearchProbeAnswer? = nil,
                foreignOrigin: ResearchProbeAnswer? = nil,
                withoutKey: ResearchProbeAnswer? = nil) {
        self.port = port
        self.path = path
        self.keySent = keySent
        self.control = control
        self.foreignHost = foreignHost
        self.foreignOrigin = foreignOrigin
        self.withoutKey = withoutKey
    }

    /// `sandseek-host-check.invalid:8080`
    public var foreignHostText: String {
        "\(ResearchHostHeaderCheck.foreignHostName):\(port)"
    }

    /// `http://sandseek-host-check.invalid:8080`
    public var foreignOriginText: String { "http://" + foreignHostText }

    /// The verdict, from the control and the foreign-host probe:
    /// - no answer to the control: `serverNotRunning`;
    /// - no key sent and the control got 401 or 403: `keyRequired`;
    /// - the control got anything but 2xx: `unclear`;
    /// - the foreign host got 400, 403, 421 or no answer: `checksHost`;
    /// - the foreign host got 2xx, like the control: `acceptsAnyHost`;
    /// - anything else: `unclear`.
    public var verdict: Verdict {
        guard let controlCode = control.statusCode else { return .serverNotRunning }
        if !keySent, controlCode == 401 || controlCode == 403 { return .keyRequired }
        guard (200..<300).contains(controlCode) else { return .unclear }
        guard let foreign = foreignHost else { return .unclear }
        guard let code = foreign.statusCode else { return .checksHost }
        if [400, 403, 421].contains(code) { return .checksHost }
        if (200..<300).contains(code) { return .acceptsAnyHost }
        return .unclear
    }

    /// True when a request without the key was refused with 401 or 403: the
    /// control itself when no key was sent, else the extra probe.
    public var keyEnforced: Bool {
        let answer: ResearchProbeAnswer? = keySent ? withoutKey : control
        guard let code = answer?.statusCode else { return false }
        return code == 401 || code == 403
    }

    /// The server answers a request that names another host, but asks for a
    /// key, so a rebinding page gets nothing.
    public var protectedByKey: Bool { verdict == .acceptsAnyHost && keyEnforced }

    /// The server answered the foreign Origin with `Access-Control-Allow-Origin`
    /// `*` or that origin, on a successful reply.
    public var allowsForeignOrigin: Bool {
        guard case .status(let code, let headers)? = foreignOrigin,
              (200..<300).contains(code),
              let allowed = headers["access-control-allow-origin"] else { return false }
        return allowed == "*" || allowed == foreignOriginText
    }

    /// A note about CORS, or nil. It is a note, not a verdict: with it, any
    /// web page can read the server's answers without rebinding, unless a key
    /// is needed.
    public var corsNote: String? {
        guard allowsForeignOrigin else { return nil }
        let lead = "The server also tells browsers that a web page from another origin may "
            + "read its answers (Access-Control-Allow-Origin), so a page needs no rebinding"
        return keyEnforced
            ? lead + ", but the server asks for a key, which such a page does not have."
            : lead + "."
    }

    /// The warning the app and the command show, or nil when nothing needs
    /// fixing. Generic: it names no product.
    public var warning: String? { warningText(for: nil) }

    /// The same warning with the way out for a known kind of server. For
    /// llama.cpp that is `--api-key-file`, which SandSeek's own start command
    /// uses.
    public func warningText(for kind: ResearchServerKind?) -> String? {
        guard verdict == .acceptsAnyHost, !protectedByKey else { return nil }
        var text = "The server answers requests that name another host "
            + "(Host: \(ResearchHostHeaderCheck.foreignHostName)). "
            + "A web page could use DNS rebinding to run prompts on it while it runs. "
            + "Quit the server when you are not researching."
        if kind == .llamacpp {
            text += " Or start llama-server with --api-key-file so that it asks for a key; "
                + "a page without the key gets nothing."
        }
        return text
    }

    /// One or two sentences on the result, for every verdict.
    public var summary: String {
        let foreignText = foreignHost?.text ?? "not sent"
        switch verdict {
        case .serverNotRunning:
            return "Nothing answers on port \(port), so the Host header could not be checked."
        case .keyRequired:
            var text = "The server asks for a key (\(control.text) without one), so a web page "
                + "that rebinds to it, which has none, gets nothing."
            if let foreign = foreignHost, foreign.statusCode != control.statusCode {
                text += " A request that names another host got \(foreign.text)."
            }
            return text
        case .checksHost:
            let how = foreignHost?.statusCode == nil
                ? "does not answer" : "refuses (\(foreignText))"
            return "The server \(how) a request that names another host, so a web page "
                + "that rebinds its own host name to this Mac gets no answer."
        case .acceptsAnyHost:
            if protectedByKey {
                return "The server answers requests that name another host, but it asks for a "
                    + "key, which a rebinding web page does not have."
            }
            return warning ?? ""
        case .unclear:
            if let code = control.statusCode, keySent, code == 401 || code == 403 {
                return "Cannot tell: the server refused the key that was sent (HTTP \(code))."
            }
            if let code = control.statusCode, !(200..<300).contains(code) {
                return "Cannot tell: the normal request for \(path) got HTTP \(code), "
                    + "not a success."
            }
            return "Cannot tell: the normal request got \(control.text) and the request "
                + "that names another host got \(foreignText)."
        }
    }
}

// MARK: - The check

public enum ResearchHostHeaderCheck {
    /// A host name that never resolves (the `.invalid` TLD is reserved for
    /// that), so a server that answers a request for it answers any Host.
    public static let foreignHostName = "sandseek-host-check.invalid"

    /// Seconds one request may take in all (connect, send, read).
    public static let defaultTimeout: TimeInterval = 3.0

    /// The read-only path that is asked: the model list. Ollama's own is
    /// `/api/tags`; TUFF, llama.cpp and a server of unknown kind get the
    /// OpenAI-style list.
    public static func requestPath(for kind: ResearchServerKind?) -> String {
        kind == .ollama ? "/api/tags" : "/v1/models"
    }

    /// The loopback address to connect to for the host of `url`, or nil when
    /// it is not a loopback address: `127.0.0.1` and `localhost` give
    /// 127.0.0.1, `::1` gives ::1.
    public static func loopbackAddress(for url: URL) -> ResearchHostAddress? {
        switch url.host?.lowercased() {
        case "127.0.0.1", "localhost": return .ipv4(127, 0, 0, 1)
        case "::1", "[::1]": return ResearchHostAddress.ipv6(groups: [0, 0, 0, 0, 0, 0, 0, 1])
        default: return nil
        }
    }

    /// Runs the probes against `port` on `address`. A `authorization` that is
    /// not safe in a header (CR, LF, other control characters) is not sent.
    public static func run(
        port: Int,
        kind: ResearchServerKind?,
        authorization: String? = nil,
        address: ResearchHostAddress = .ipv4(127, 0, 0, 1),
        prober: any ResearchHTTPProbing = ResearchSocketHTTPProber(),
        timeout: TimeInterval = ResearchHostHeaderCheck.defaultTimeout
    ) async -> ResearchHostHeaderReport {
        let path = requestPath(for: kind)
        let key = authorization.flatMap {
            ResearchHostHeaderRequest.isSafeHeaderValue($0) ? $0 : nil
        }
        let normalHost = address.hostAndPort(port)
        let foreignHost = "\(foreignHostName):\(port)"
        let foreignOrigin = "http://\(foreignHost)"

        let control = await prober.get(
            port: port, path: path, host: normalHost, origin: nil, authorization: key,
            timeout: timeout)
        // Nothing answers: the other requests would say nothing.
        guard control.statusCode != nil else {
            return ResearchHostHeaderReport(
                port: port, path: path, keySent: key != nil, control: control)
        }
        async let foreignAnswer = prober.get(
            port: port, path: path, host: foreignHost, origin: nil, authorization: key,
            timeout: timeout)
        async let originAnswer = prober.get(
            port: port, path: path, host: normalHost, origin: foreignOrigin, authorization: key,
            timeout: timeout)
        let foreign = await foreignAnswer
        let origin = await originAnswer
        var bare: ResearchProbeAnswer?
        if key != nil {
            bare = await prober.get(
                port: port, path: path, host: normalHost, origin: nil, authorization: nil,
                timeout: timeout)
        }
        return ResearchHostHeaderReport(
            port: port, path: path, keySent: key != nil, control: control,
            foreignHost: foreign, foreignOrigin: origin, withoutKey: bare)
    }
}

// MARK: - The command's report

/// The text and exit status of `sandseek --check-host-header`.
public enum ResearchHostHeaderCommand {
    /// The server refuses another Host, asks for a key, or answers any Host
    /// but asks for a key.
    public static let exitFine: Int32 = 0
    /// Bad arguments (`sandseek` uses 2 for those everywhere).
    public static let exitBadArguments: Int32 = 2
    /// The server answers any Host and needs no key.
    public static let exitAcceptsAnyHost: Int32 = 3
    /// Nothing answers on this port: cannot tell.
    public static let exitServerNotRunning: Int32 = 4
    /// Odd answers: cannot tell.
    public static let exitUnclear: Int32 = 5

    public static func run(
        port: Int,
        serverKind: ResearchServerKind? = nil,
        authorization: String? = nil,
        address: ResearchHostAddress = .ipv4(127, 0, 0, 1),
        prober: any ResearchHTTPProbing = ResearchSocketHTTPProber(),
        timeout: TimeInterval = ResearchHostHeaderCheck.defaultTimeout
    ) async -> (text: String, exitCode: Int32) {
        let report = await ResearchHostHeaderCheck.run(
            port: port, kind: serverKind, authorization: authorization, address: address,
            prober: prober, timeout: timeout)
        return render(report: report, address: address, serverKind: serverKind)
    }

    private static func line(_ label: String, _ detail: String, _ answer: ResearchProbeAnswer?)
        -> String {
        let result = answer.map(\.text) ?? "not sent"
        return "  \(label): \(detail) -> \(result)"
    }

    static func render(report: ResearchHostHeaderReport,
                       address: ResearchHostAddress = .ipv4(127, 0, 0, 1),
                       serverKind: ResearchServerKind? = nil) -> (text: String, exitCode: Int32) {
        let normalHost = address.hostAndPort(report.port)
        var lines = [
            "Host header check: does the model server refuse a request that names another host?",
            "A web page can use DNS rebinding to reach a server on this Mac under its own host name.",
            "Only GET \(report.path) was sent; no prompt. A key, if one was given, is sent as a "
                + "header and never printed.",
            "",
            "Model server, port \(report.port):",
            line("1. normal request", "Host: \(normalHost)", report.control),
            line("2. another host", "Host: \(report.foreignHostText)", report.foreignHost),
        ]
        var third = line("3. another origin", "Origin: \(report.foreignOriginText)",
                         report.foreignOrigin)
        if report.allowsForeignOrigin { third += " (allows that origin)" }
        lines.append(third)
        if report.keySent {
            lines.append(line("4. normal, without the key", "Host: \(normalHost)",
                              report.withoutKey))
        }
        lines.append("")

        let exitCode: Int32
        switch report.verdict {
        case .serverNotRunning:
            exitCode = exitServerNotRunning
            lines.append("RESULT: cannot tell. Nothing answers on port \(report.port). "
                + "Start the model server on that port, then run this check again.")
        case .unclear:
            exitCode = exitUnclear
            lines.append("RESULT: " + report.summary)
        case .checksHost, .keyRequired:
            exitCode = exitFine
            lines.append("RESULT: " + report.summary)
        case .acceptsAnyHost:
            exitCode = report.protectedByKey ? exitFine : exitAcceptsAnyHost
            lines.append("RESULT: " + (report.warningText(for: serverKind) ?? report.summary))
        }
        if let note = report.corsNote {
            lines.append("NOTE: " + note)
        }
        return (lines.joined(separator: "\n"), exitCode)
    }
}
