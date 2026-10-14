import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SandSeekCore

/// SandSeek's client never follows a redirect. The sandbox and the model
/// server are on loopback and never redirect, so a 3xx means another program
/// holds the port, and following it would send the client (and a 307's POST
/// body, and the llama.cpp key) wherever that program says.

// The real-socket tests run on macOS only. The refusal is a macOS guarantee:
// on Linux, Foundation follows the redirects of completion-handler tasks
// without asking the delegate (see `ResearchNoRedirectDelegate`).
#if canImport(Darwin)

/// A minimal HTTP server on 127.0.0.1 and a port the system chooses. It
/// answers every request with one fixed reply, closes the connection, and
/// counts the requests it got. It reads a whole request (head and the body
/// the head announces) before it answers, so a client never sees a reset.
private final class LoopbackHTTPServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let status: Int
    private let location: String?
    private let lock = NSLock()
    private var stopped = false
    private var heads: [String] = []

    /// `location` is sent as the `Location` header when given.
    init?(status: Int, location: String? = nil) {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let made = socket(AF_INET, streamType, 0)
        guard made >= 0 else { return nil }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(made, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(made, 8) == 0 else {
            close(made)
            return nil
        }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(made, generic, &length)
            }
        }
        guard result == 0 else {
            close(made)
            return nil
        }
        listener = made
        port = Int(UInt16(bigEndian: named.sin_port))
        self.status = status
        self.location = location
        Thread.detachNewThread { [self] in serve() }
    }

    /// How many requests came in.
    var requestCount: Int { lock.withLock { heads.count } }
    /// The head (request line and headers) of each request, in order.
    var requestHeads: [String] { lock.withLock { heads } }

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Ends the server; the thread closes the listening socket.
    func stop() {
        lock.withLock { stopped = true }
    }

    private func serve() {
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 50) > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            answer(client)
            close(client)
        }
        close(listener)
    }

    private func answer(_ client: Int32) {
        let head = readRequest(client)
        guard !head.isEmpty else { return }
        lock.withLock { heads.append(head) }
        let body = status == 200 ? "{}" : #"{"moved":true}"#
        var reply = "HTTP/1.1 \(status) Answer\r\n"
        if let location { reply += "Location: \(location)\r\n" }
        reply += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        reply += "Connection: close\r\n\r\n" + body
        let bytes = Array(reply.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { raw in
                write(client, raw.baseAddress, raw.count)
            }
            if count <= 0 { break }
            sent += count
        }
    }

    /// The request's head, once the whole request has arrived (at most 2 s
    /// of silence is waited for). Empty when nothing came.
    private func readRequest(_ client: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var wanted: Int?
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let end = data.range(of: separator) {
                if wanted == nil {
                    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                    wanted = end.upperBound + Self.contentLength(in: head)
                }
                if let wanted, data.count >= wanted { break }
            }
            var waiting = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 2_000) > 0 else { break }
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        guard let end = data.range(of: separator) else { return "" }
        return String(decoding: data[..<end.lowerBound], as: UTF8.self)
    }

    private static func contentLength(in head: String) -> Int {
        for line in head.split(separator: "\r\n") {
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                return Int(lowered.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }
}

#endif

/// Answers every request with a fixed status and a body that would pass for a
/// healthy sandbox or model server, as a program that took over a port might.
private struct AlwaysRedirects: ResearchHTTPTransport {
    let status: Int

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        ResearchHTTPResponse(status: status, body: Data(
            #"{"passages":true,"results":[],"choices":[{"message":{"content":"hi"}}],"error":{"message":"from the other program"}}"#.utf8))
    }
}

private let redirectStatuses = [301, 302, 303, 307, 308]

@Suite struct ResearchRedirectRefusalTests {
    private let sandbox = URL(string: "http://127.0.0.1:9100")!
    private let modelServer = URL(string: "http://127.0.0.1:8080")!

    private func chat(_ transport: any ResearchHTTPTransport, streaming: Bool) -> ResearchChatClient {
        ResearchChatClient(serverURL: modelServer, model: "m", maxTokens: 64,
                           enableThinking: nil, streaming: streaming, transport: transport)
    }

    @Test func theMessageSaysPlainlyWhatHappened() {
        let text = ResearchError.redirectRefused(status: 307).description
        #expect(text.contains("redirect (HTTP 307)"))
        #expect(text.contains("SandSeek refuses"))
        #expect(text.contains("another program may be using the port"))
    }

    @Test(arguments: redirectStatuses)
    func theSandboxClientTreatsARedirectAsAnError(status: Int) async {
        let client = ResearchSandboxClient.forTests(baseURL: sandbox, transport: AlwaysRedirects(status: status))
        let expected = ResearchError.redirectRefused(status: status)
        await #expect(throws: expected) { try await client.checkHealth() }
        await #expect(throws: expected) { try await client.checkHealth(requirePassages: true) }
        await #expect(throws: expected) { _ = try await client.search(query: "q", maxResults: 3) }
        await #expect(throws: expected) {
            _ = try await client.fetch(url: "https://example.com", offset: 0, maxCharacters: 100)
        }
    }

    @Test(arguments: redirectStatuses)
    func theChatClientTreatsARedirectAsAnErrorStreamingOrNot(status: Int) async {
        let expected = ResearchError.redirectRefused(status: status)
        for streaming in [false, true] {
            let client = chat(AlwaysRedirects(status: status), streaming: streaming)
            await #expect(throws: expected) {
                _ = try await client.complete(messages: [], tools: [])
            }
        }
    }

    @Test(arguments: redirectStatuses)
    func choosingTheServerRefusesARedirectInsteadOfContinuing(status: Int) async {
        let expected = ResearchError.redirectRefused(status: status)
        // `tuff` would otherwise only warn and go on; `auto` would otherwise
        // send the user to `--server-type llamacpp`.
        for choice in [ResearchServerChoice.tuff, .auto] {
            await #expect(throws: expected) {
                _ = try await ResearchServerConnection.establish(
                    choice: choice, stream: nil, serverURL: modelServer,
                    transport: AlwaysRedirects(status: status))
            }
        }
    }

    @Test func otherAnswersAreUnchanged() async throws {
        // A 404 from the status route is still "not TUFF", not a redirect.
        await #expect(throws: ResearchError.self) {
            _ = try await ResearchServerConnection.establish(
                choice: .auto, stream: nil, serverURL: modelServer,
                transport: AlwaysRedirects(status: 404))
        }
        let notFound = ResearchSandboxClient.forTests(baseURL: sandbox, transport: AlwaysRedirects(status: 503))
        await #expect(throws: ResearchError.sandboxUnavailable("health check answered HTTP 503")) {
            try await notFound.checkHealth()
        }
    }
}

#if canImport(Darwin)

/// The real transport against real servers on loopback: one answers with a
/// redirect to the other, and the other must never hear from the client.
@Suite struct ResearchNoRedirectTransportTests {
    private static let secret = "Bearer not-a-real-key"

    private func servers(status: Int) throws -> (squatter: LoopbackHTTPServer, target: LoopbackHTTPServer) {
        let target = try #require(LoopbackHTTPServer(status: 200))
        let squatter = LoopbackHTTPServer(
            status: status, location: "http://127.0.0.1:\(target.port)/v1/chat/completions")
        if squatter == nil { target.stop() }
        return (try #require(squatter), target)
    }

    @Test(arguments: redirectStatuses)
    func aRedirectIsReturnedAndNeverFollowed(status: Int) async throws {
        let (squatter, target) = try servers(status: status)
        defer {
            squatter.stop()
            target.stop()
        }
        let transport = URLSessionResearchTransport(timeout: 10)
        let url = squatter.url.appendingPathComponent("v1/chat/completions")
        let body = Data(#"{"messages":[]}"#.utf8)

        // `data(for:)`: a POST that a 307 or 308 would have sent again.
        let plain = try await transport.send(
            method: "POST", url: url, body: body, timeout: nil, authorization: Self.secret)
        #expect(plain.status == status)
        #expect(plain.isRedirect)
        #expect(squatter.requestCount >= 1)

        // `bytes(for:)`.
        let streamed = try await transport.sendStreaming(
            method: "POST", url: url, body: body, timeout: nil, authorization: Self.secret)
        #expect(streamed.status == status)
        #expect(streamed.isRedirect)

        // A GET, as the health checks send.
        let get = try await transport.send(method: "GET", url: url, body: nil)
        #expect(get.status == status)

        // Give a client that followed late a moment to show up.
        try await Task.sleep(for: .milliseconds(200))
        #expect(target.requestCount == 0, "the redirect target was contacted")
        #expect(squatter.requestCount >= 3)
    }

    @Test func theCallersFailAndTheTargetIsNeverContacted() async throws {
        let (squatter, target) = try servers(status: 307)
        defer {
            squatter.stop()
            target.stop()
        }
        let transport = URLSessionResearchTransport(timeout: 10)
        let expected = ResearchError.redirectRefused(status: 307)

        let sandbox = ResearchSandboxClient(
            baseURL: squatter.url, transport: transport, secretFile: TestSandboxSecret.file)
        await #expect(throws: expected) { try await sandbox.checkHealth() }
        await #expect(throws: expected) { _ = try await sandbox.search(query: "q", maxResults: 3) }
        await #expect(throws: expected) {
            _ = try await sandbox.fetch(url: "https://example.com", offset: 0, maxCharacters: 100)
        }

        for streaming in [false, true] {
            let chat = ResearchChatClient(
                serverURL: squatter.url, model: "m", maxTokens: 64, enableThinking: nil,
                streaming: streaming, authorization: Self.secret, transport: transport)
            await #expect(throws: expected) {
                _ = try await chat.complete(messages: [], tools: [])
            }
        }
        await #expect(throws: expected) {
            _ = try await ResearchServerConnection.establish(
                choice: .auto, stream: nil, serverURL: squatter.url, transport: transport)
        }

        try await Task.sleep(for: .milliseconds(200))
        #expect(target.requestCount == 0, "the redirect target was contacted")
        #expect(squatter.requestCount >= 6)
    }

    @Test func aServerThatDoesNotRedirectStillWorks() async throws {
        // The delegate must not get in the way of an ordinary answer.
        let plain = try #require(LoopbackHTTPServer(status: 200))
        defer { plain.stop() }
        let transport = URLSessionResearchTransport(timeout: 10)
        let response = try await transport.send(
            method: "POST", url: plain.url, body: Data("{}".utf8), timeout: nil,
            authorization: Self.secret)
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "{}")
        #expect(plain.requestHeads.first?.lowercased()
            .contains("authorization: " + Self.secret.lowercased()) == true)
        let streamed = try await transport.sendStreaming(
            method: "POST", url: plain.url, body: Data("{}".utf8), timeout: nil,
            authorization: nil)
        #expect(streamed.status == 200)
        var lines: [String] = []
        for try await line in streamed.lines { lines.append(line) }
        #expect(lines == ["{}"])
    }
}

#endif
