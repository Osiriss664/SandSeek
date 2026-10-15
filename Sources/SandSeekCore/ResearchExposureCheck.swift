import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// "Is the model server reachable from the network?"
//
// SandSeek only ever talks to a model server on 127.0.0.1. Whether the server
// also listens on the Mac's network addresses is decided by how it was started
// (a `--host 0.0.0.0` or a wildcard default). This file lists the Mac's own
// non-loopback addresses and tries a plain TCP connect to each one on the
// server's port. A connect that is accepted means someone on that network
// could reach the server too. A connect that is refused (ECONNREFUSED, which
// the Mac's own network stack answers at once) means nothing listens there.
// Anything else (a timeout, "no route", "not permitted", for example macOS
// Local Network privacy or a firewall rule) is neither: the check says it
// could not tell, never "not reachable". Nothing is sent over the connection:
// it is closed at once, so no HTTP request reaches the server and no key is
// used.

// MARK: - Addresses

/// One of this Mac's own network addresses: IPv4 (4 bytes) or IPv6 (16 bytes),
/// in network byte order.
public struct ResearchHostAddress: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]

    /// Nil unless `bytes` has 4 (IPv4) or 16 (IPv6) entries.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public static func ipv4(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ fourth: UInt8)
        -> ResearchHostAddress {
        ResearchHostAddress(bytes: [first, second, third, fourth])!
    }

    /// An IPv6 address from its eight 16-bit groups, as written between the
    /// colons. Nil unless there are exactly eight.
    public static func ipv6(groups: [UInt16]) -> ResearchHostAddress? {
        guard groups.count == 8 else { return nil }
        var bytes: [UInt8] = []
        for group in groups {
            bytes.append(UInt8(group >> 8))
            bytes.append(UInt8(group & 0xff))
        }
        return ResearchHostAddress(bytes: bytes)
    }

    public var isIPv6: Bool { bytes.count == 16 }

    /// The usual text form: dotted decimal for IPv4, lower-case hex with the
    /// longest run of zero groups written as `::` for IPv6.
    public var text: String {
        if !isIPv6 { return bytes.map { String($0) }.joined(separator: ".") }
        var groups: [UInt16] = []
        for index in 0..<8 {
            let high = UInt16(bytes[2 * index]) << 8
            let low = UInt16(bytes[2 * index + 1])
            groups.append(high | low)
        }
        // The first longest run of at least two zero groups becomes "::".
        var bestStart = -1
        var bestLength = 0
        var index = 0
        while index < 8 {
            if groups[index] != 0 {
                index += 1
                continue
            }
            var end = index
            while end < 8 && groups[end] == 0 { end += 1 }
            if end - index > bestLength {
                bestStart = index
                bestLength = end - index
            }
            index = end
        }
        if bestLength < 2 {
            return groups.map { String($0, radix: 16) }.joined(separator: ":")
        }
        let head = groups[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
        let tail = groups[(bestStart + bestLength)...].map { String($0, radix: 16) }
            .joined(separator: ":")
        return head + "::" + tail
    }

    /// `address:port`, with an IPv6 address in brackets.
    public func hostAndPort(_ port: Int) -> String {
        isIPv6 ? "[\(text)]:\(port)" : "\(text):\(port)"
    }

    /// True for an address that another machine could use to reach this Mac.
    /// Not these, which the check skips:
    /// - loopback (127.0.0.0/8, ::1): the server is meant to answer there;
    /// - link-local (169.254.0.0/16, fe80::/10): they need an interface
    ///   scope to connect to, and a server that listens on every address
    ///   answers on the Mac's other addresses too;
    /// - "this network" (0.0.0.0/8), the unspecified address `::`, multicast
    ///   and reserved ranges, which no interface holds as its own address.
    public var isNetworkAddress: Bool {
        if !isIPv6 { return Self.isNetworkIPv4(bytes) }
        // ::ffff:a.b.c.d is judged by the IPv4 address inside it.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return Self.isNetworkIPv4(Array(bytes[12..<16]))
        }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        return true
    }

    private static func isNetworkIPv4(_ bytes: [UInt8]) -> Bool {
        if bytes[0] == 0 || bytes[0] == 127 { return false }
        if bytes[0] == 169, bytes[1] == 254 { return false }
        if bytes[0] >= 224 { return false }
        return true
    }

    /// The addresses of `all` that `isNetworkAddress` accepts, once each,
    /// IPv4 before IPv6 and in numeric order.
    public static func networkAddresses(from all: [ResearchHostAddress]) -> [ResearchHostAddress] {
        var seen = Set<ResearchHostAddress>()
        let wanted = all.filter { $0.isNetworkAddress && seen.insert($0).inserted }
        return wanted.sorted { left, right in
            if left.isIPv6 != right.isIPv6 { return !left.isIPv6 }
            return left.bytes.lexicographicallyPrecedes(right.bytes)
        }
    }

    /// This Mac's own network addresses that another machine could connect
    /// to, from the interfaces that are up.
    public static func localNetworkAddresses() -> [ResearchHostAddress] {
        networkAddresses(from: interfaceAddresses())
    }

    /// Every IPv4 and IPv6 address of every interface that is up and not a
    /// loopback interface, as `getifaddrs` lists them.
    static func interfaceAddresses() -> [ResearchHostAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var found: [ResearchHostAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            // IFF_UP is 0x1 and IFF_LOOPBACK 0x8 on macOS and on Linux. The
            // numbers are written out because the constants are imported with
            // different types on the two systems.
            let flags = UInt32(entry.pointee.ifa_flags)
            guard flags & 0x1 != 0, flags & 0x8 == 0 else { continue }
            guard let socketAddress = entry.pointee.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            if family == AF_INET {
                let bytes: [UInt8] = socketAddress.withMemoryRebound(
                    to: sockaddr_in.self, capacity: 1
                ) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin_addr) { raw in Array(raw.prefix(4)) }
                }
                if let address = ResearchHostAddress(bytes: bytes) { found.append(address) }
            } else if family == AF_INET6 {
                let bytes: [UInt8] = socketAddress.withMemoryRebound(
                    to: sockaddr_in6.self, capacity: 1
                ) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { raw in Array(raw.prefix(16)) }
                }
                if let address = ResearchHostAddress(bytes: bytes) { found.append(address) }
            }
        }
        return found
    }
}

// MARK: - Connecting

/// What a TCP connection attempt to one address and port came to.
public enum ResearchPortAnswer: Equatable, Sendable {
    /// The connection was accepted: something listens there.
    case accepted
    /// The connection was refused (ECONNREFUSED): nothing listens there.
    case refused
    /// Neither: it timed out or failed in another way (blocked, no route,
    /// not permitted, an error in the probe itself).
    case unknown
}

/// Tries a TCP connection and says how it came out. A fake stands in for it
/// in tests.
public protocol ResearchPortConnecting: Sendable {
    /// Connects to `address` on `port`, waiting up to `timeout` seconds, and
    /// closes the connection at once; nothing is sent.
    func answer(address: ResearchHostAddress, port: Int, timeout: TimeInterval) async
        -> ResearchPortAnswer
}

/// The real thing: a POSIX socket, set to non-blocking, connected with `poll`
/// as the time limit. It runs on a dispatch queue so that it never blocks one
/// of the threads Swift concurrency uses.
public struct ResearchTCPConnector: ResearchPortConnecting {
    public init() {}

    public func answer(address: ResearchHostAddress, port: Int, timeout: TimeInterval) async
        -> ResearchPortAnswer {
        let bytes = address.bytes
        let milliseconds = Int32(min(max(timeout, 0.05), 60) * 1000)
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<ResearchPortAnswer, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.attempt(
                    bytes: bytes, port: port, timeoutMilliseconds: milliseconds))
            }
        }
    }

    private static func attempt(bytes: [UInt8], port: Int,
                                timeoutMilliseconds: Int32) -> ResearchPortAnswer {
        guard let portNumber = UInt16(exactly: port), portNumber != 0 else { return .unknown }
        let isIPv6 = bytes.count == 16
        guard isIPv6 || bytes.count == 4 else { return .unknown }
        // Glibc imports SOCK_STREAM as an enum with a raw value; macOS and
        // musl import it as an integer.
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(isIPv6 ? AF_INET6 : AF_INET, streamType, 0)
        guard descriptor >= 0 else { return .unknown }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return .unknown }

        let started: Int32
        if isIPv6 {
            var socketAddress = sockaddr_in6()
            #if canImport(Darwin)
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = portNumber.bigEndian
            withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { $0.copyBytes(from: bytes) }
            started = withUnsafePointer(to: socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var socketAddress = sockaddr_in()
            #if canImport(Darwin)
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = portNumber.bigEndian
            withUnsafeMutableBytes(of: &socketAddress.sin_addr) { $0.copyBytes(from: bytes) }
            started = withUnsafePointer(to: socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        // A connect to an address of this Mac usually finishes (accepted or
        // refused) at once; a filtered one needs the wait below. Only a refusal
        // counts as "nothing listens there": a block, a missing permission or
        // a timeout leaves the question open.
        let connectError = errno
        if started == 0 { return .accepted }
        if connectError == ECONNREFUSED { return .refused }
        guard connectError == EINPROGRESS else { return .unknown }

        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        var ready: Int32 = -1
        for _ in 0..<3 {
            ready = poll(&waiting, 1, timeoutMilliseconds)
            if ready >= 0 || errno != EINTR { break }
        }
        guard ready > 0 else { return .unknown }
        // Writable can also mean "failed": the socket's own error says which.
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else {
            return .unknown
        }
        if failure == 0 { return .accepted }
        return failure == ECONNREFUSED ? .refused : .unknown
    }
}

// MARK: - The check

/// What the check found for one port.
public struct ResearchExposureReport: Equatable, Sendable {
    public let port: Int
    /// Whether anything accepted a connection on this Mac's loopback address
    /// (127.0.0.1 or ::1). When not, the server is not running there, and
    /// "nothing answered on the network" proves nothing.
    public let loopbackAnswered: Bool
    /// The network addresses that were tried.
    public let checked: [ResearchHostAddress]
    /// The ones that accepted a connection.
    public let reachable: [ResearchHostAddress]
    /// The ones that neither accepted nor refused (a timeout or another
    /// failure). Together with `reachable` these are the addresses for which
    /// "refused" was not seen.
    public let unknown: [ResearchHostAddress]

    public init(port: Int, loopbackAnswered: Bool,
                checked: [ResearchHostAddress], reachable: [ResearchHostAddress],
                unknown: [ResearchHostAddress] = []) {
        self.port = port
        self.loopbackAnswered = loopbackAnswered
        self.checked = checked
        self.reachable = reachable
        self.unknown = unknown
    }

    public var isExposed: Bool { !reachable.isEmpty }

    /// True if at least one address gave neither an acceptance nor a refusal.
    public var hasUnknown: Bool { !unknown.isEmpty }

    /// How many addresses refused the connection.
    public var refusedCount: Int { max(0, checked.count - reachable.count - unknown.count) }

    /// `192.168.1.5:8080, [2001:db8::5]:8080`
    public var reachableText: String {
        reachable.map { $0.hostAndPort(port) }.joined(separator: ", ")
    }

    /// `192.168.1.5:8080` for each address that gave no clear answer.
    public var unknownText: String {
        unknown.map { $0.hostAndPort(port) }.joined(separator: ", ")
    }

    /// The warning the app and the command show, or nil when nothing
    /// answered on the network. It names no flag for every server type: TUFF
    /// has none, and listens on 127.0.0.1 only by itself.
    public var warning: String? { warning(for: nil) }

    /// The same warning with the way out for a known kind of server. Ollama
    /// listens where `OLLAMA_HOST` says, so its advice names that variable
    /// (never `0.0.0.0`, which is every network address). Without a kind the
    /// advice is the llama.cpp flag.
    public func warning(for kind: ResearchServerKind?) -> String? {
        guard isExposed else { return nil }
        let lead = "Something answers at \(reachableText). "
            + "Other machines on that network can reach it. "
        if kind == .ollama {
            return lead + "Start Ollama with OLLAMA_HOST=127.0.0.1:11434 so that it listens "
                + "on 127.0.0.1 only."
        }
        return lead + "Start the server so that it listens on 127.0.0.1 only "
            + "(llama-server: --host 127.0.0.1)."
    }

    /// The note the app and the command show when some address gave no clear
    /// answer, or nil.
    public var unknownNote: String? {
        guard hasUnknown else { return nil }
        let noun = unknown.count == 1 ? "address" : "addresses"
        return "Could not tell for \(unknown.count) \(noun) (\(unknownText)): the connection "
            + "was neither accepted nor refused. If macOS asked SandSeek for Local Network "
            + "access, allow it (System Settings > Privacy & Security > Local Network) "
            + "and check again."
    }
}

public enum ResearchExposureCheck {
    /// Seconds to wait for one address. A closed port on one of the Mac's own
    /// addresses answers at once; the wait only matters for a filtered one.
    public static let defaultTimeout: TimeInterval = 1.0

    public static let loopbackAddresses: [ResearchHostAddress] = [
        .ipv4(127, 0, 0, 1),
        ResearchHostAddress.ipv6(groups: [0, 0, 0, 0, 0, 0, 0, 1])!,
    ]

    /// Tries `port` on this Mac's loopback addresses and on each of
    /// `addresses` (default: the Mac's own network addresses), all at once.
    public static func run(
        port: Int,
        addresses: [ResearchHostAddress]? = nil,
        connector: any ResearchPortConnecting = ResearchTCPConnector(),
        timeout: TimeInterval = ResearchExposureCheck.defaultTimeout
    ) async -> ResearchExposureReport {
        let toCheck = ResearchHostAddress.networkAddresses(
            from: addresses ?? ResearchHostAddress.localNetworkAddresses())
        let onLoopback = await answers(
            loopbackAddresses, port: port, connector: connector, timeout: timeout)
        let onNetwork = await answers(
            toCheck, port: port, connector: connector, timeout: timeout)
        var reachable: [ResearchHostAddress] = []
        var unknown: [ResearchHostAddress] = []
        for (address, answer) in zip(toCheck, onNetwork) {
            switch answer {
            case .accepted: reachable.append(address)
            case .unknown: unknown.append(address)
            case .refused: break
            }
        }
        return ResearchExposureReport(
            port: port, loopbackAnswered: onLoopback.contains(.accepted),
            checked: toCheck, reachable: reachable, unknown: unknown)
    }

    /// How each of `addresses` answered, in their order.
    static func answers(_ addresses: [ResearchHostAddress],
                        port: Int,
                        connector: any ResearchPortConnecting,
                        timeout: TimeInterval) async -> [ResearchPortAnswer] {
        await withTaskGroup(of: (Int, ResearchPortAnswer).self,
                            returning: [ResearchPortAnswer].self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask {
                    (index, await connector.answer(address: address, port: port, timeout: timeout))
                }
            }
            var result = [ResearchPortAnswer](repeating: .unknown, count: addresses.count)
            for await (index, answer) in group {
                result[index] = answer
            }
            return result
        }
    }
}

// MARK: - The command's report

/// The text and exit status of `sandseek --check-exposure`.
public enum ResearchExposureCommand {
    /// Nothing answered on the network, and every address refused.
    public static let exitClear: Int32 = 0
    /// Bad arguments (`sandseek` uses 2 for those everywhere).
    public static let exitBadArguments: Int32 = 2
    /// Something answered on the network.
    public static let exitExposed: Int32 = 3
    /// Nothing answered on the network, but the model server does not answer
    /// on this Mac either, so the result says nothing.
    public static let exitServerNotRunning: Int32 = 4
    /// Nothing accepted, but some address neither accepted nor refused (for
    /// example macOS Local Network privacy or a firewall rule), so the result
    /// says nothing.
    public static let exitUnclear: Int32 = 5

    /// Checks the model server's port and the web sandbox's port. Only the
    /// model server's port decides "not running": the sandbox is started and
    /// stopped by the app, and a stopped sandbox is nothing to report.
    public static func run(
        serverPort: Int,
        sandboxPort: Int,
        addresses: [ResearchHostAddress]? = nil,
        connector: any ResearchPortConnecting = ResearchTCPConnector(),
        timeout: TimeInterval = ResearchExposureCheck.defaultTimeout,
        serverKind: ResearchServerKind? = nil
    ) async -> (text: String, exitCode: Int32) {
        // Listing the interfaces once keeps the two ports on the same addresses.
        let list = ResearchHostAddress.networkAddresses(
            from: addresses ?? ResearchHostAddress.localNetworkAddresses())
        let server = await ResearchExposureCheck.run(
            port: serverPort, addresses: list, connector: connector, timeout: timeout)
        let sandbox = await ResearchExposureCheck.run(
            port: sandboxPort, addresses: list, connector: connector, timeout: timeout)
        return render(server: server, sandbox: sandbox, serverKind: serverKind)
    }

    /// The line about one port's network addresses.
    private static func networkLine(_ report: ResearchExposureReport) -> [String] {
        var lines: [String] = []
        if report.isExposed {
            lines.append("  answers on the network: YES, at \(report.reachableText)")
        } else if report.hasUnknown {
            lines.append("  answers on the network: NOT KNOWN (no answer and no refusal from "
                + "\(report.unknownText))")
        } else if report.checked.isEmpty {
            lines.append("  answers on the network: no")
        } else {
            let noun = report.checked.count == 1 ? "address" : "addresses"
            lines.append("  answers on the network: no (all \(report.checked.count) \(noun) "
                + "refused the connection)")
        }
        if report.isExposed, report.hasUnknown {
            lines.append("  no clear answer from: \(report.unknownText)")
        }
        return lines
    }

    static func render(server: ResearchExposureReport,
                       sandbox: ResearchExposureReport,
                       serverKind: ResearchServerKind? = nil) -> (text: String, exitCode: Int32) {
        var lines = [
            "Network exposure check: does a connection to this Mac's own network addresses succeed?",
            "A plain TCP connect only; nothing is sent to the servers. A connection that is",
            "refused counts as \"nothing listens\"; a timeout or any other failure is \"not known\".",
        ]
        if server.checked.isEmpty {
            lines.append("This Mac has no network address besides loopback, so there is nothing to try.")
        } else {
            lines.append("Addresses tried: " + server.checked.map(\.text).joined(separator: ", "))
        }
        lines.append("")
        lines.append("Model server, port \(server.port):")
        lines.append(server.loopbackAnswered
            ? "  answers on 127.0.0.1 or ::1: yes"
            : "  answers on 127.0.0.1 or ::1: NO (the server is not running here)")
        lines.append(contentsOf: networkLine(server))
        lines.append("")
        lines.append("Web sandbox, port \(sandbox.port):")
        lines.append(sandbox.loopbackAnswered
            ? "  answers on 127.0.0.1 or ::1: yes"
            : "  answers on 127.0.0.1 or ::1: no (not running; that is fine)")
        lines.append(contentsOf: networkLine(sandbox))
        lines.append("")

        let exitCode: Int32
        if server.isExposed || sandbox.isExposed {
            exitCode = exitExposed
            if let warning = server.warning(for: serverKind) {
                lines.append("RESULT: " + warning)
            }
            if sandbox.isExposed {
                lines.append("RESULT: the web sandbox is reachable from the network at "
                    + "\(sandbox.reachableText); it must be published on 127.0.0.1 only "
                    + "(Scripts/research_sandbox.sh start does that)")
            }
        } else if !server.loopbackAnswered {
            exitCode = exitServerNotRunning
            lines.append("RESULT: cannot tell. Nothing answers on port \(server.port) at all. "
                + "Start the model server on that port, then run this check again.")
        } else if let note = server.unknownNote ?? sandbox.unknownNote {
            exitCode = exitUnclear
            lines.append("RESULT: cannot tell. " + note)
        } else {
            exitCode = exitClear
            lines.append("RESULT: nothing answered on the network.")
        }
        return (lines.joined(separator: "\n"), exitCode)
    }
}
