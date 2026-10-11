import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ResearchHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data
    /// The response headers, with the names in lower case. Empty from a
    /// transport that does not read them, such as the test fakes.
    public let headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// A 3xx answer. `URLSessionResearchTransport` never follows a redirect,
    /// so the 3xx itself comes back; every caller treats it as an error
    /// (`ResearchError.redirectRefused`).
    public var isRedirect: Bool { (300..<400).contains(status) }
}

/// The start of a streamed reply: the HTTP status, known as soon as the
/// headers arrive, and the body as it comes, one text line at a time. Lines
/// end at LF, CR or CRLF only (see `SSELineBuffer`); a line holds no line
/// terminator, and an empty line may or may not appear.
///
/// The stream ends when the server has sent everything. If the request fails
/// on the way (the time limit, a lost connection) the stream throws that
/// error. When the consuming task is cancelled, or the consumer stops reading
/// and drops the stream, the transport cancels the request and closes the
/// connection.
public struct ResearchHTTPLineResponse: Sendable {
    public let status: Int
    public let lines: AsyncThrowingStream<String, any Error>

    public init(status: Int, lines: AsyncThrowingStream<String, any Error>) {
        self.status = status
        self.lines = lines
    }

    /// A 3xx answer; see `ResearchHTTPResponse.isRedirect`.
    public var isRedirect: Bool { (300..<400).contains(status) }

    /// A reply that is already complete, such as a test fixture or the body
    /// of a transport that cannot stream: its bytes split into lines by the
    /// same splitter the streaming transport uses (`SSELineBuffer`).
    public init(status: Int, body: Data) {
        self.init(status: status, chunks: [body])
    }

    /// A complete reply that arrived in pieces, cut anywhere, even inside a
    /// multi-byte character or between a CR and its LF.
    init(status: Int, chunks: [Data]) {
        self.init(status: status, lines: AsyncThrowingStream<String, any Error> { continuation in
            var buffer = SSELineBuffer()
            for chunk in chunks {
                for line in buffer.read(contentsOf: chunk) { continuation.yield(line) }
            }
            if let rest = buffer.finish() { continuation.yield(rest) }
            continuation.finish()
        })
    }
}

/// Splits bytes into the lines of a server-sent events stream: at LF (0x0A),
/// CR (0x0D) and CRLF, which counts as one line end, and nowhere else.
/// Foundation's `AsyncLineSequence` (`bytes.lines`) also breaks at U+0085,
/// U+2028 and U+2029, which JSON text may hold unescaped (TUFF's
/// `JSONSerialization` writes them as they are), so it must not be used.
///
/// 0x0A and 0x0D never occur inside a multi-byte UTF-8 sequence, so cutting
/// the bytes there is safe; each line is decoded as UTF-8 after it is cut.
/// Empty lines are lines. A CR ends its line at once, without waiting for
/// the byte after it. The buffer holds only the current, unfinished line, so
/// the input may arrive in pieces of any size.
struct SSELineBuffer: Sendable {
    private var line: [UInt8] = []
    private var skipLineFeed = false

    /// Reads one byte; returns the line it completes, if it does.
    mutating func read(_ byte: UInt8) -> String? {
        switch byte {
        case 0x0A:
            if skipLineFeed {
                skipLineFeed = false
                return nil
            }
            return takeLine()
        case 0x0D:
            skipLineFeed = true
            return takeLine()
        default:
            skipLineFeed = false
            line.append(byte)
            return nil
        }
    }

    /// Reads a piece of the input; returns the lines it completes.
    mutating func read<Bytes: Sequence>(contentsOf bytes: Bytes) -> [String]
    where Bytes.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            if let completed = read(byte) { lines.append(completed) }
        }
        return lines
    }

    /// The input is over: the last line, which needs no terminator, unless
    /// it is empty.
    mutating func finish() -> String? {
        line.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return text
    }
}

/// The lines of a byte sequence, cut by `SSELineBuffer`. Generic so that the
/// URLSession transport and the tests run the same code.
struct SSELines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base

    init(_ base: Base) {
        self.base = base
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Base.AsyncIterator
        var buffer = SSELineBuffer()
        var ended = false

        mutating func next() async throws -> String? {
            while !ended {
                guard let byte = try await bytes.next() else {
                    ended = true
                    break
                }
                if let line = buffer.read(byte) { return line }
            }
            return buffer.finish()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes: base.makeAsyncIterator())
    }
}

/// One JSON POST or GET to a loopback service. Tests replace it with a fake;
/// the command uses `URLSessionResearchTransport`.
public protocol ResearchHTTPTransport: Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse
    /// The same, given up with `URLError(.timedOut)` after `timeout` seconds
    /// when that is sooner than the transport's own timeout.
    func send(method: String, url: URL, body: Data?,
              timeout: TimeInterval?) async throws -> ResearchHTTPResponse
    /// The same request, answered as a stream of lines (server-sent events).
    /// It returns as soon as the status is known. `timeout` counts from the
    /// call and covers the whole reply, as it does for `send`: the stream
    /// throws `URLError(.timedOut)` when it runs out.
    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse
    /// The same as the request above, with an optional `Authorization` header
    /// value such as `Bearer <key>` (llama.cpp started with `--api-key`). The
    /// value goes into that one header and nowhere else: not into the body,
    /// the URL, an error message or a log. A transport that cannot send a
    /// header (every test fake) gets the default below, which leaves it out.
    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse
    /// The streaming form of the request above, with the same header.
    func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                       authorization: String?) async throws -> ResearchHTTPLineResponse
    /// The same as the request above, with more request headers (the sandbox's
    /// `X-Sandbox-Nonce`); the response carries its headers. A transport that
    /// cannot send headers gets the default below, which refuses to drop them.
    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse
}

public extension ResearchHTTPTransport {
    func send(method: String, url: URL, body: Data?,
              timeout: TimeInterval?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: timeout)
    }

    func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                       authorization: String?) async throws -> ResearchHTTPLineResponse {
        try await sendStreaming(method: method, url: url, body: body, timeout: timeout)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        guard headers.isEmpty else {
            throw ResearchError.sandboxUnavailable("this transport cannot send request headers")
        }
        return try await send(method: method, url: url, body: body, timeout: timeout,
                              authorization: authorization)
    }

    /// For a transport that cannot stream (every test fake): the whole reply
    /// from `send`, split into lines. Nothing arrives before the reply is
    /// complete, but the lines are the same ones a streaming transport gives.
    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        let response = try await send(method: method, url: url, body: body, timeout: timeout)
        return ResearchHTTPLineResponse(status: response.status, body: response.body)
    }
}

/// Refuses every redirect, so that the 3xx answer itself is the response.
///
/// Both services SandSeek talks to (the sandbox and the model server) are on
/// loopback and never redirect. A program that took over their port could
/// answer with a 3xx and send the client to another address, with none of the
/// address checks the sandbox makes, and a 307 or 308 would send the POST body
/// again, possibly with the `Authorization` header (the llama.cpp key).
///
/// This is a guarantee on macOS. On Linux, Foundation follows the redirects of
/// a task made with a completion handler (as `data(for:)` is there) without
/// asking the delegate, so the same code does not protect there; SandSeek's
/// app and sandbox run on macOS only.
///
/// The class has no state, which is why `@unchecked Sendable` is safe;
/// `NSObject` is needed because `URLSessionTaskDelegate` is an Objective-C
/// protocol.
final class ResearchNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // nil: do not follow. The redirect response is delivered as the
        // task's response, with its status and body.
        completionHandler(nil)
    }
}

/// Holds the session of a transport, and its delegate, and ends the session
/// with the last copy of the transport. A session with a delegate keeps that
/// delegate, and itself, alive until it is invalidated; without this, every
/// transport SandSeek makes would leave its session behind. Requests still
/// under way finish first.
private final class ResearchSessionOwner: Sendable {
    let session: URLSession
    /// Also handed to each request (`data(for:delegate:)`, `bytes(for:delegate:)`),
    /// so that the redirect refusal does not depend on the session's own
    /// delegate being asked for tasks made by the async methods.
    let noRedirect: ResearchNoRedirectDelegate

    init(configuration: URLSessionConfiguration) {
        let delegate = ResearchNoRedirectDelegate()
        noRedirect = delegate
        session = URLSession(configuration: configuration, delegate: delegate,
                             delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }
}

public struct URLSessionResearchTransport: ResearchHTTPTransport {
    /// The one session of this transport. `send` (`data(for:)`) and
    /// `sendStreaming` (`bytes(for:)`) both use it, and nothing else in
    /// SandSeek creates a URLSession, so its delegate covers every request.
    private let owner: ResearchSessionOwner
    private var session: URLSession { owner.session }

    /// Model turns can take minutes on large streamed models: Qwen3.6 35B
    /// on a 16 GB Mac needed 858 s for one turn that reasoned for its whole
    /// token limit. So the request timeout is generous; the sandbox enforces
    /// its own fetch timeouts.
    public init(timeout: TimeInterval = 1_800) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // Both services are on loopback. A system proxy must never see them.
        configuration.connectionProxyDictionary = [:]
        // No response cache: every answer must come from the server. An
        // ephemeral session still keeps an in-memory cache, which served a
        // repeated request to a 301 or 308 without asking the server (Mac
        // test, 11.10.), and a cached signed answer would not match a fresh
        // nonce anyway.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Never follow a redirect (see `ResearchNoRedirectDelegate`). The
        // session retains the delegate. A nil delegate queue gives the
        // session its own serial queue.
        owner = ResearchSessionOwner(configuration: configuration)
    }

    public func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: nil, authorization: nil)
    }

    public func send(method: String, url: URL, body: Data?,
                     timeout: TimeInterval?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: timeout,
                       authorization: nil)
    }

    /// A request given up at `timeout` is cancelled, which closes its
    /// connection; TUFF then stops generating the abandoned reply instead of
    /// making the next request wait for it.
    public func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                     authorization: String?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: timeout,
                       authorization: authorization, headers: [:])
    }

    /// The same, with more request headers (names as they are sent). The
    /// response's headers come back with their names in lower case.
    public func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                     authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        guard let timeout else {
            return try await fetch(method: method, url: url, body: body,
                                   authorization: authorization, headers: headers)
        }
        return try await withThrowingTaskGroup(of: ResearchHTTPResponse.self) { group in
            group.addTask {
                try await fetch(method: method, url: url, body: body,
                                authorization: authorization, headers: headers)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    private func fetch(method: String, url: URL, body: Data?, authorization: String?,
                       headers: [String: String]) async throws -> ResearchHTTPResponse {
        let request = Self.makeRequest(method: method, url: url, body: body,
                                       accept: "application/json", authorization: authorization,
                                       headers: headers)
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        #else
        // Read with a limit: a program on a loopback port must not make
        // SandSeek hold an endless answer in memory before it is checked.
        let (bytes, response) = try await session.bytes(for: request, delegate: owner.noRedirect)
        if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumResponseBytes {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        #endif
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ResearchHTTPResponse(status: status, body: data,
                                    headers: Self.lowercasedHeaders(of: response))
    }

    /// The most a `send` reads of one answer. The sandbox's and the model
    /// server's answers are far smaller (a page slice is at most 20,000
    /// characters; a model turn is a few thousand tokens).
    static let maximumResponseBytes = 16 * 1024 * 1024

    /// The headers of an HTTP reply, with the names in lower case. A name that
    /// came twice is one entry, as `URLSession` joins the values.
    static func lowercasedHeaders(of response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return headers
    }

    static func makeRequest(method: String, url: URL, body: Data?,
                            accept: String, authorization: String? = nil,
                            headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // The only place the key goes: a header, never the body or the URL.
        if let authorization, !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    public func sendStreaming(method: String, url: URL, body: Data?,
                              timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        try await sendStreaming(method: method, url: url, body: body, timeout: timeout,
                                authorization: nil)
    }

    #if canImport(FoundationNetworking)
    /// A transport that cannot stream gives the whole reply as lines.
    public func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                              authorization: String?) async throws -> ResearchHTTPLineResponse {
        let response = try await send(method: method, url: url, body: body, timeout: timeout,
                                      authorization: authorization)
        return ResearchHTTPLineResponse(status: response.status, body: response.body)
    }
    #endif

    #if !canImport(FoundationNetworking)
    /// Sends the request and gives the reply as lines while it arrives.
    ///
    /// Why this exists: TUFF notices that a client has hung up only when it
    /// next writes to the connection. A request that waits for the whole
    /// reply never gives it that chance, and TUFF goes on generating a reply
    /// nobody reads. A streamed reply gives it one write per token and a
    /// heartbeat every few seconds, so cancelling this call (the task is
    /// cancelled, the consumer stops reading, the time limit runs out) closes
    /// the connection and TUFF stops at its next write.
    ///
    /// Time limits. `timeout` is the thinking limit and runs from this call
    /// to the last line, as in `send`. The session's request timeout stays
    /// the step limit and is not changed for streaming: a reply may be silent
    /// for minutes while the server reads in a long prompt (llama.cpp sends
    /// nothing at all then), and that must never be cut off early. There is
    /// no idle timer of our own.
    public func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                              authorization: String?) async throws -> ResearchHTTPLineResponse {
        let started = ContinuousClock.now
        let request = Self.makeRequest(method: method, url: url, body: body,
                                       accept: "text/event-stream", authorization: authorization)
        let session = self.session
        let noRedirect = owner.noRedirect
        // Up to the headers, with the same task group as `send`. Cancelling
        // the group's task cancels `bytes(for:)`.
        let opened = try await Self.withinTimeLimit(timeout) {
            let (bytes, response) = try await session.bytes(for: request, delegate: noRedirect)
            // Not `bytes.lines`: see `SSELineBuffer`.
            return OpenedLines(lines: SSELines(bytes),
                               status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var remaining: TimeInterval?
        if let timeout {
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            remaining = max(0, timeout - seconds)
        }
        let limit = remaining
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let reader = Task {
                do {
                    for try await line in opened.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // The time limit is a watchdog task and not a task group around
            // the reader: it ends the stream at once even if the byte
            // iterator is slow to react to cancellation.
            let watchdog: Task<Void, Never>? = limit.map { limit in
                Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    } catch {
                        return
                    }
                    continuation.finish(throwing: URLError(.timedOut))
                    reader.cancel()
                }
            }
            // The consumer stopped reading, was cancelled or saw the end:
            // cancelling the reader cancels the request and closes the
            // connection.
            continuation.onTermination = { _ in
                reader.cancel()
                watchdog?.cancel()
            }
        }
        return ResearchHTTPLineResponse(status: opened.status, lines: lines)
    }

    /// The lines of an open reply. The byte sequence is not known to be
    /// `Sendable`; this value is made once, then handed to the single task
    /// that reads it, and never used anywhere else.
    private struct OpenedLines: @unchecked Sendable {
        let lines: SSELines<URLSession.AsyncBytes>
        let status: Int
    }

    private static func withinTimeLimit<T: Sendable>(
        _ timeout: TimeInterval?,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let timeout else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }
    #endif
}

public enum ResearchError: Error, Equatable, CustomStringConvertible {
    case invalidEndpoint(String)
    case modelUnavailable(String)
    /// One model turn took longer than the request timeout.
    case modelTimedOut
    case modelRequestFailed(status: Int, message: String, code: String?)
    case malformedModelReply(String)
    case sandboxUnavailable(String)
    /// The sandbox runs an older server that cannot rank passages.
    case sandboxCannotRankPassages
    /// The model ended a turn with neither an answer nor a tool call, twice.
    case noAnswer(tokenLimit: Bool)
    /// The sandbox or the model server answered with a 3xx. SandSeek's client
    /// never follows redirects, and neither service redirects legitimately.
    case redirectRefused(status: Int)
    /// The sandbox's secret file exists but cannot be used (see
    /// `ResearchSandboxSecret`). The message says what is wrong with it, and
    /// never holds the secret.
    case sandboxSecretUnusable(String)
    /// An answer from the sandbox's port is not signed with the sandbox's
    /// secret. `address` is the host and port, such as `127.0.0.1:9100`.
    case sandboxNotSigned(address: String)

    public var description: String {
        switch self {
        case .invalidEndpoint(let message):
            message
        case .modelUnavailable(let message):
            "could not reach the model server: \(message). Start TUFF's Background API "
                + "(or `tuff serve`)."
        case .modelTimedOut:
            "one model step took longer than the request time limit. The model may be too "
                + "slow on this Mac for this question; try fewer steps, or thinking off."
        case .modelRequestFailed(let status, let message, _):
            "the model server refused the request (HTTP \(status)): \(message)"
        case .malformedModelReply(let message):
            "the model server sent a reply the research loop cannot read: \(message)"
        case .sandboxUnavailable(let message):
            "could not reach the web research sandbox: \(message). "
                + "Start it with `Scripts/research_sandbox.sh start`."
        case .sandboxCannotRankPassages:
            ResearchSandboxClient.passagesUnsupportedMessage
        case .noAnswer(tokenLimit: true):
            "the model used its whole token limit before writing an answer, usually by "
                + "thinking. Try a larger --max-tokens, or --thinking off."
        case .noAnswer(tokenLimit: false):
            "the model ended without writing an answer. Try again, or try another model."
        case .redirectRefused(let status):
            "something on that port answered with a redirect (HTTP \(status)), which SandSeek "
                + "refuses. It never follows redirects from the sandbox or the model server, "
                + "and neither of them redirects, so another program may be using the port."
        case .sandboxSecretUnusable(let message):
            "the sandbox's secret file cannot be used: \(message)"
        case .sandboxNotSigned(let address):
            "the answer on \(address) is not signed by the SandSeek sandbox; "
                + "another program may be using the port"
        }
    }
}

public enum ResearchEndpoint {
    /// Both services must be plain HTTP on this Mac's loopback address. The
    /// TUFF server has no authentication and must stay local, and the sandbox
    /// is published only to loopback.
    public static func loopbackURL(_ text: String, flag: String) throws -> URL {
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else {
            throw ResearchError.invalidEndpoint(
                "\(flag) must be an http URL on 127.0.0.1, localhost or ::1, such as "
                    + "http://127.0.0.1:8080")
        }
        var trimmed = url.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)!
    }
}
