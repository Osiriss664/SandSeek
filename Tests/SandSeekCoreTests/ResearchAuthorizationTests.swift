import Foundation
import Testing
@testable import SandSeekCore

/// A transport that records what each request carried in the
/// `Authorization` slot, and answers a plain reply or a stream.
private final class AuthRecorder: ResearchHTTPTransport, @unchecked Sendable {
    struct Seen: Equatable {
        let method: String
        let path: String
        let authorization: String?
        let body: String
        let streamed: Bool
    }

    private let lock = NSLock()
    private var recorded: [Seen] = []

    var seen: [Seen] { lock.withLock { recorded } }

    private func record(_ method: String, _ url: URL, _ body: Data?, _ authorization: String?,
                        streamed: Bool) {
        lock.withLock {
            recorded.append(Seen(
                method: method, path: url.path, authorization: authorization,
                body: body.map { String(decoding: $0, as: UTF8.self) } ?? "",
                streamed: streamed))
        }
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: nil, authorization: nil)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse {
        record(method, url, body, authorization, streamed: false)
        if url.path == "/v1/models" {
            return ResearchHTTPResponse(status: 200, body: Data(
                #"{"data":[{"id":"m","context_length":8192}]}"#.utf8))
        }
        return ResearchHTTPResponse(status: 200, body: Data(
            #"{"model":"m","choices":[{"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#.utf8))
    }

    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        try await sendStreaming(method: method, url: url, body: body, timeout: timeout,
                                authorization: nil)
    }

    func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                       authorization: String?) async throws -> ResearchHTTPLineResponse {
        record(method, url, body, authorization, streamed: true)
        let stream = """
        data: {"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

        data: {"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        return ResearchHTTPLineResponse(status: 200, body: Data(stream.utf8))
    }
}

private let secret = "Bearer 0123456789abcdef-test-key"
private let serverURL = URL(string: "http://127.0.0.1:8081")!

private func client(_ transport: AuthRecorder, streaming: Bool,
                    authorization: String?) -> ResearchChatClient {
    ResearchChatClient(serverURL: serverURL, model: "m", maxTokens: 64, enableThinking: nil,
                       streaming: streaming, authorization: authorization,
                       transport: transport)
}

private func ask(_ client: ResearchChatClient) async throws -> ResearchAssistantTurn {
    try await client.complete(
        messages: [.object(["role": .string("user"), "content": .string("Hello")])],
        tools: [])
}

@Suite("Authorization header")
struct ResearchAuthorizationTests {
    @Test func aPlainRequestCarriesTheHeaderOnly() async throws {
        let transport = AuthRecorder()
        _ = try await ask(client(transport, streaming: false, authorization: secret))
        let seen = try #require(transport.seen.first)
        #expect(seen.path == "/v1/chat/completions")
        #expect(seen.authorization == secret)
        #expect(!seen.streamed)
        // Never in the request body.
        #expect(!seen.body.contains("test-key"))
        #expect(!seen.body.contains("Bearer"))
    }

    @Test func aStreamedRequestCarriesTheHeaderOnly() async throws {
        let transport = AuthRecorder()
        let turn = try await ask(client(transport, streaming: true, authorization: secret))
        #expect(turn.content == "Hi")
        let seen = try #require(transport.seen.first)
        #expect(seen.streamed)
        #expect(seen.authorization == secret)
        #expect(!seen.body.contains("test-key"))
    }

    @Test func theModelListCarriesTheHeaderToo() async throws {
        let transport = AuthRecorder()
        let models = await client(transport, streaming: false, authorization: secret)
            .listedModels()
        #expect(models.map { $0.id } == ["m"])
        let seen = try #require(transport.seen.first)
        #expect(seen.method == "GET")
        #expect(seen.path == "/v1/models")
        #expect(seen.authorization == secret)
    }

    @Test func withoutAKeyNoHeaderIsSent() async throws {
        let transport = AuthRecorder()
        _ = try await ask(client(transport, streaming: false, authorization: nil))
        _ = try await ask(client(transport, streaming: true, authorization: nil))
        #expect(transport.seen.count == 2)
        #expect(transport.seen.allSatisfy { $0.authorization == nil })
    }

    @Test func aTransportWithoutHeaderSupportStillWorks() async throws {
        // Every fake in the agent tests implements only `send`; the key is
        // left out for them and the request goes through.
        final class SendOnly: ResearchHTTPTransport, @unchecked Sendable {
            func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
                ResearchHTTPResponse(status: 200, body: Data(
                    #"{"choices":[{"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#.utf8))
            }
        }
        let chat = ResearchChatClient(
            serverURL: serverURL, model: "m", maxTokens: 64, enableThinking: nil,
            authorization: secret, transport: SendOnly())
        #expect(try await ask(chat).content == "Hi")
    }

    @Test func theURLSessionRequestSetsTheHeaderAndNotTheURL() throws {
        let url = URL(string: "http://127.0.0.1:8081/v1/chat/completions")!
        let request = URLSessionResearchTransport.makeRequest(
            method: "POST", url: url, body: Data("{}".utf8), accept: "application/json",
            authorization: secret)
        #expect(request.value(forHTTPHeaderField: "Authorization") == secret)
        #expect(request.url == url)
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "{}")

        let plain = URLSessionResearchTransport.makeRequest(
            method: "GET", url: url, body: nil, accept: "application/json")
        #expect(plain.value(forHTTPHeaderField: "Authorization") == nil)
        let empty = URLSessionResearchTransport.makeRequest(
            method: "GET", url: url, body: nil, accept: "application/json", authorization: "")
        #expect(empty.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
