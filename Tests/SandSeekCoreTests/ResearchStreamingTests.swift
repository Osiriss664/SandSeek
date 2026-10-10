import Foundation
import Testing
@testable import SandSeekCore

// The fixtures below are written the way TUFF 8.3.1 writes a stream
// (Sources/TUFFServer/Core/HTTPServer.swift at 58ae663): a first chunk that
// carries only the role; `: ping` heartbeat comments between chunks; text and
// reasoning as `delta.content` and `delta.reasoning_content`; every tool call
// in pieces, with id, type and name only in the first; a final chunk with
// `finish_reason` and `tuff_timings_seconds`; with `include_usage` a chunk
// with `choices: []`; then `data: [DONE]`. A failure after the stream has
// started is `data: {"error":{…}}` and `data: [DONE]`, with HTTP status 200.
// Replace them with real recordings (Scripts/record_stream.py) on the Mac.

private enum Fixture {
    /// Reasoning and an answer over many chunks. The text starts and ends
    /// with white space that must survive.
    static let answer = #"""
    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    : ping

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"reasoning_content":"Okay, the user "},"finish_reason":null}]}

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"reasoning_content":"wants a short answer.\n"},"finish_reason":null}]}

    : ping

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"reasoning_content":"</think>\n\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"content":"\n\nEine "},"finish_reason":null}]}

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"content":"Wärme"},"finish_reason":null}]}

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"content":"pumpe nutzt "},"finish_reason":null}]}

    : ping

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"content":"Umgebungswärme. [1]\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"tuff_timings_seconds":{"queued":0.0004,"prepare":0.112,"prefill":2.481,"generate":4.207}}

    data: {"id":"chatcmpl-5f2c0e8a","object":"chat.completion.chunk","created":1760105000,"model":"qwen3.6-35b-a3b","choices":[],"usage":{"prompt_tokens":1834,"completion_tokens":61,"total_tokens":1895,"prompt_tokens_details":{"cached_tokens":1792},"completion_tokens_details":{"reasoning_tokens":23}}}

    data: [DONE]


    """#

    /// What the stream above says, as the full message a server without
    /// streaming would return.
    static let answerContent = "\n\nEine Wärmepumpe nutzt Umgebungswärme. [1]\n"
    static let answerReasoning = "Okay, the user wants a short answer.\n</think>\n\n"

    /// The same stream without the usage chunk.
    static let answerWithoutUsage = answer
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("\"choices\":[],\"usage\"") }
        .joined(separator: "\n")

    /// Two tool calls, each in pieces. TUFF writes the calls one after the
    /// other, each in fragments of at most 1,024 bytes.
    static let toolCalls = #"""
    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    : ping

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"reasoning_content":"I should search first.\n</think>\n\n"},"finish_reason":null}]}

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1a2b3c","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"Wärme"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"pumpe Förderung 2026\"}"}}]},"finish_reason":null}]}

    : ping

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_4d5e6f","type":"function","function":{"name":"open_page","arguments":"{\"url\":\"https://exam"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"ple.org/"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"a\"}"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"tuff_timings_seconds":{"queued":0.0003,"prepare":0.098,"prefill":1.9,"generate":2.2}}

    data: {"id":"chatcmpl-91d7a3b0","object":"chat.completion.chunk","created":1760105100,"model":"qwen3.6-35b-a3b","choices":[],"usage":{"prompt_tokens":2048,"completion_tokens":44,"total_tokens":2092,"prompt_tokens_details":{"cached_tokens":0}}}

    data: [DONE]


    """#

    /// A failure after the stream started and after some text: HTTP 200, the
    /// error inside the stream, then `[DONE]`.
    static let contextError = #"""
    data: {"id":"chatcmpl-c0ffee01","object":"chat.completion.chunk","created":1760105200,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    data: {"id":"chatcmpl-c0ffee01","object":"chat.completion.chunk","created":1760105200,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"content":"Die Antwort beginnt "},"finish_reason":null}]}

    : ping

    data: {"error":{"message":"effective prompt exceeds the configured context","type":"invalid_request_error","param":"messages","code":"context_length_exceeded"}}

    data: [DONE]


    """#

    /// An internal failure: TUFF writes code `internal_error`, type `server_error`.
    static let serverError = #"""
    data: {"id":"chatcmpl-c0ffee02","object":"chat.completion.chunk","created":1760105300,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    data: {"id":"chatcmpl-c0ffee02","object":"chat.completion.chunk","created":1760105300,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"reasoning_content":"Let me think"},"finish_reason":null}]}

    data: {"error":{"message":"generation failed; see TUFFServer stderr","type":"server_error","code":"internal_error"}}

    data: [DONE]


    """#

    /// The connection ends in the middle of the answer.
    static let endsEarly = #"""
    data: {"id":"chatcmpl-dead0001","object":"chat.completion.chunk","created":1760105400,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

    : ping

    data: {"id":"chatcmpl-dead0001","object":"chat.completion.chunk","created":1760105400,"model":"qwen3.6-35b-a3b","choices":[{"index":0,"delta":{"content":"Eine halbe "},"finish_reason":null}]}

    """#
}

/// Answers the chat endpoint from a stream fixture (through the streaming
/// method) or from a ready response (through `send`), and records the
/// requests it got.
private final class StreamFake: ResearchHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let stream: String?
    private let plain: ResearchHTTPResponse?
    private var bodies: [Data] = []
    private var limits: [TimeInterval?] = []
    private var streamed = 0

    init(stream: String, status: Int = 200) {
        self.status = status
        self.stream = stream
        plain = nil
    }

    init(plain: ResearchHTTPResponse) {
        status = plain.status
        stream = nil
        self.plain = plain
    }

    var requestBodies: [Data] { lock.withLock { bodies } }
    var timeLimits: [TimeInterval?] { lock.withLock { limits } }
    var streamingCalls: Int { lock.withLock { streamed } }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        if let body { lock.withLock { bodies.append(body) } }
        return plain ?? ResearchHTTPResponse(status: status, body: Data((stream ?? "").utf8))
    }

    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        lock.withLock {
            if let body { bodies.append(body) }
            limits.append(timeout)
            streamed += 1
        }
        return ResearchHTTPLineResponse(status: status, body: Data((stream ?? "").utf8))
    }
}

/// A transport that implements only `send`, as every fake in the agent tests
/// does: `sendStreaming` is the default from the protocol extension.
private final class SendOnly: ResearchHTTPTransport, @unchecked Sendable {
    private let response: ResearchHTTPResponse

    init(_ response: ResearchHTTPResponse) {
        self.response = response
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        response
    }
}

/// A stream that never ends, and a flag that says when it was closed.
private final class HangingStream: ResearchHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpened = false
    private var isClosed = false

    var opened: Bool { lock.withLock { isOpened } }
    var closed: Bool { lock.withLock { isClosed } }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        ResearchHTTPResponse(status: 500, body: Data())
    }

    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        lock.withLock { isOpened = true }
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            continuation.yield(#"data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#)
            continuation.onTermination = { @Sendable [self] _ in
                lock.withLock { isClosed = true }
            }
        }
        return ResearchHTTPLineResponse(status: 200, lines: lines)
    }
}

/// A stream that gives a role chunk and then fails.
private final class FailingStream: ResearchHTTPTransport, @unchecked Sendable {
    private let error: URLError

    init(_ error: URLError) {
        self.error = error
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        ResearchHTTPResponse(status: 500, body: Data())
    }

    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        let failure = error
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            continuation.yield(#"data: {"choices":[{"index":0,"delta":{"content":"Ein"},"finish_reason":null}]}"#)
            continuation.finish(throwing: failure)
        }
        return ResearchHTTPLineResponse(status: 200, lines: lines)
    }
}

private let serverURL = URL(string: "http://127.0.0.1:8080")!

private func client(_ transport: any ResearchHTTPTransport, streaming: Bool,
                    enableThinking: Bool? = nil) -> ResearchChatClient {
    ResearchChatClient(serverURL: serverURL, model: "qwen36", maxTokens: 512,
                       enableThinking: enableThinking, streaming: streaming,
                       transport: transport)
}

private func complete(_ client: ResearchChatClient,
                      timeout: TimeInterval? = nil) async throws -> ResearchAssistantTurn {
    try await client.complete(
        messages: [.object(["role": .string("user"), "content": .string("Hallo")])],
        tools: [], timeout: timeout)
}

/// The error `complete` throws, or nil when it returns.
private func failure(_ client: ResearchChatClient) async -> ResearchError? {
    do {
        _ = try await complete(client)
        return nil
    } catch let error as ResearchError {
        return error
    } catch {
        Issue.record("not a ResearchError: \(error)")
        return nil
    }
}

private func collect(_ response: ResearchHTTPLineResponse) async throws -> [String] {
    var lines: [String] = []
    for try await line in response.lines { lines.append(line) }
    return lines
}

/// What a server without streaming returns for a full message.
private func plainReply(content: String?, reasoning: String? = nil,
                        toolCalls: [(String, String, String)] = [],
                        finishReason: String, promptTokens: Int?,
                        model: String) -> ResearchHTTPResponse {
    var message: [String: ResearchJSON] = [
        "role": .string("assistant"),
        "content": content.map(ResearchJSON.string) ?? .null,
    ]
    if let reasoning { message["reasoning_content"] = .string(reasoning) }
    if !toolCalls.isEmpty {
        message["tool_calls"] = .array(toolCalls.map { id, name, arguments in
            .object([
                "id": .string(id),
                "type": .string("function"),
                "function": .object(["name": .string(name), "arguments": .string(arguments)]),
            ])
        })
    }
    var reply: [String: ResearchJSON] = [
        "model": .string(model),
        "choices": .array([.object([
            "message": .object(message),
            "finish_reason": .string(finishReason),
        ])]),
    ]
    if let promptTokens {
        reply["usage"] = .object(["prompt_tokens": .integer(promptTokens)])
    }
    return ResearchHTTPResponse(status: 200, body: (try? ResearchJSON.object(reply).encoded()) ?? Data())
}

@Suite("Web research streaming")
struct ResearchStreamingTests {
    // MARK: the stream becomes the same turn

    @Test func contentAndReasoningAcrossManyChunksEqualTheNonStreamedTurn() async throws {
        let streamed = try await complete(client(StreamFake(stream: Fixture.answer), streaming: true))
        let plain = try await complete(client(StreamFake(plain: plainReply(
            content: Fixture.answerContent, reasoning: Fixture.answerReasoning,
            finishReason: "stop", promptTokens: 1_834, model: "qwen3.6-35b-a3b")),
            streaming: false))
        #expect(streamed == plain)
        // And in particular: nothing trimmed, the model named, the usage read.
        #expect(streamed.content == Fixture.answerContent)
        #expect(streamed.reasoning == Fixture.answerReasoning)
        #expect(streamed.toolCalls.isEmpty)
        #expect(streamed.finishReason == "stop")
        #expect(streamed.promptTokens == 1_834)
        #expect(streamed.model == "qwen3.6-35b-a3b")
    }

    @Test func twoToolCallsWithArgumentsInPiecesAreJoinedByIndex() async throws {
        let streamed = try await complete(client(StreamFake(stream: Fixture.toolCalls), streaming: true))
        let first = ResearchToolCall(
            id: "call_1a2b3c", name: "web_search",
            arguments: #"{"query":"Wärmepumpe Förderung 2026"}"#)
        let second = ResearchToolCall(
            id: "call_4d5e6f", name: "open_page",
            arguments: #"{"url":"https://example.org/a"}"#)
        #expect(streamed.toolCalls == [first, second])
        #expect(streamed.content == nil)
        #expect(streamed.reasoning == "I should search first.\n</think>\n\n")
        #expect(streamed.finishReason == "tool_calls")
        #expect(streamed.promptTokens == 2_048)
        let plain = try await complete(client(StreamFake(plain: plainReply(
            content: nil, reasoning: "I should search first.\n</think>\n\n",
            toolCalls: [(first.id, first.name, first.arguments),
                        (second.id, second.name, second.arguments)],
            finishReason: "tool_calls", promptTokens: 2_048, model: "qwen3.6-35b-a3b")),
            streaming: false))
        #expect(streamed == plain)
    }

    @Test func aMissingUsageChunkIsFine() async throws {
        let turn = try await complete(client(
            StreamFake(stream: Fixture.answerWithoutUsage), streaming: true))
        #expect(turn.promptTokens == nil)
        #expect(turn.content == Fixture.answerContent)
        #expect(turn.finishReason == "stop")
    }

    // MARK: errors

    @Test func anErrorAfterSomeTextIsTheErrorTheAgentActsOn() async {
        let error = await failure(client(StreamFake(stream: Fixture.contextError), streaming: true))
        #expect(error == .modelRequestFailed(
            status: 400, message: "effective prompt exceeds the configured context",
            code: "context_length_exceeded"))
        // The patterns the agent matches (ResearchAgent.send and .complete).
        guard case .modelRequestFailed(let status, _, let code)? = error else {
            Issue.record("expected modelRequestFailed, got \(String(describing: error))")
            return
        }
        #expect(code == "context_length_exceeded")
        #expect(status < 500, "context_length_exceeded must not be retried as a server error")
    }

    @Test func aServerErrorInTheStreamIs500AndIsRetried() async {
        let error = await failure(client(StreamFake(stream: Fixture.serverError), streaming: true))
        #expect(error == .modelRequestFailed(
            status: 500, message: "generation failed; see TUFFServer stderr",
            code: "internal_error"))
        guard case .modelRequestFailed(let status, _, let code)? = error else {
            Issue.record("expected modelRequestFailed, got \(String(describing: error))")
            return
        }
        // ResearchAgent.complete retries when status >= 500 and the code is
        // not one of ResearchAgent.answeredErrors.
        #expect(status >= 500)
        #expect(!ResearchAgent.answeredErrors.contains(code ?? ""))
    }

    @Test func aStreamEndingEarlyIsAMalformedReply() async {
        let error = await failure(client(StreamFake(stream: Fixture.endsEarly), streaming: true))
        guard case .malformedModelReply(_)? = error else {
            Issue.record("expected malformedModelReply, got \(String(describing: error))")
            return
        }
    }

    @Test func aRefusalBeforeTheStreamIsHandledAsWithoutStreaming() async {
        let body = """
        {
          "error": {
            "message": "unsupported chat_template_kwargs field",
            "type": "invalid_request_error",
            "param": "chat_template_kwargs",
            "code": "unknown_parameter"
          }
        }
        """
        let refusal = ResearchHTTPResponse(status: 400, body: Data(body.utf8))
        let expected = ResearchError.modelRequestFailed(
            status: 400, message: "unsupported chat_template_kwargs field",
            code: "unknown_parameter")
        // `SendOnly` has no streaming of its own: the default splits the body.
        #expect(await failure(client(SendOnly(refusal), streaming: false)) == expected)
        #expect(await failure(client(SendOnly(refusal), streaming: true)) == expected)
        #expect(await failure(client(StreamFake(stream: body, status: 400), streaming: true)) == expected)
    }

    @Test func aRefusalWithoutJSONKeepsTheBodyAsTheMessage() async {
        let refusal = ResearchHTTPResponse(status: 503, body: Data("busy".utf8))
        #expect(await failure(client(SendOnly(refusal), streaming: true))
            == .modelRequestFailed(status: 503, message: "busy", code: nil))
    }

    @Test func aStreamThatFailsOnTheWayMapsLikeToday() async {
        let timedOut = await failure(client(FailingStream(URLError(.timedOut)), streaming: true))
        #expect(timedOut == .modelTimedOut)
        let lost = await failure(client(
            FailingStream(URLError(.networkConnectionLost)), streaming: true))
        guard case .modelUnavailable(_)? = lost else {
            Issue.record("expected modelUnavailable, got \(String(describing: lost))")
            return
        }
    }

    // MARK: stopping

    @Test func cancellingTheTaskClosesTheStream() async {
        let transport = HangingStream()
        let chat = client(transport, streaming: true)
        let task = Task { try await complete(chat) }
        for _ in 0..<300 where !transport.opened {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(transport.opened)
        task.cancel()
        let result = await task.result
        if case .failure(let error) = result {
            #expect(error is CancellationError, "\(error)")
        } else {
            Issue.record("a cancelled request must not return a turn")
        }
        for _ in 0..<300 where !transport.closed {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(transport.closed, "the transport must be told to close the connection")
    }

    @Test func theTimeLimitIsPassedToTheTransport() async throws {
        let transport = StreamFake(stream: Fixture.answer)
        _ = try await complete(client(transport, streaming: true), timeout: 180)
        _ = try await complete(client(transport, streaming: true))
        #expect(transport.timeLimits == [180, nil])
    }

    // MARK: the request

    @Test func theStreamingBodyAsksForStreamAndUsage() async throws {
        let transport = StreamFake(stream: Fixture.answer)
        let chat = client(transport, streaming: true, enableThinking: false)
        _ = try await complete(chat)
        #expect(transport.streamingCalls == 1)
        let body = try ResearchJSON.decode(try #require(transport.requestBodies.first))
        #expect(body["stream"] == .bool(true))
        #expect(body["stream_options"] == .object(["include_usage": .bool(true)]))
        #expect(body["enable_thinking"] == .bool(false))
        #expect(body["model"] == .string("qwen36"))
        #expect(body["max_tokens"] == .integer(512))
    }

    @Test func theBodyWithoutStreamingIsTodaysBody() async throws {
        let messages: [ResearchJSON] = [
            .object(["role": .string("user"), "content": .string("Hallo")]),
        ]
        let tools: [ResearchJSON] = [.object(["type": .string("function")])]
        // The body as it was built before streaming existed.
        let today: ResearchJSON = .object([
            "model": .string("qwen36"),
            "messages": .array(messages),
            "max_tokens": .integer(512),
            "stream": .bool(false),
            "tools": .array(tools),
            "tool_choice": .string("auto"),
            "enable_thinking": .bool(false),
            "preserve_thinking": .bool(true),
        ])
        let chat = client(StreamFake(stream: ""), streaming: false, enableThinking: false)
        let body = chat.requestBody(messages: messages, tools: tools, toolUse: .allowed,
                                    preserveThinking: true)
        #expect(try body.encoded() == today.encoded())
        #expect(body["stream_options"] == nil)

        let minimal = try client(StreamFake(stream: ""), streaming: false)
            .requestBody(messages: [], tools: [], toolUse: .allowed).encoded()
        #expect(String(decoding: minimal, as: UTF8.self)
            == #"{"max_tokens":512,"messages":[],"model":"qwen36","stream":false}"#)

        // And it is what goes over the wire, through `send` and not the stream.
        let transport = StreamFake(plain: plainReply(
            content: "ok", finishReason: "stop", promptTokens: nil, model: "m"))
        _ = try await complete(client(transport, streaming: false))
        #expect(transport.streamingCalls == 0)
        let sent = try #require(transport.requestBodies.first)
        let expected = try client(transport, streaming: false).requestBody(
            messages: [.object(["role": .string("user"), "content": .string("Hallo")])],
            tools: [], toolUse: .allowed).encoded()
        #expect(sent == expected)
    }

    @Test func streamingIsOffUnlessAskedFor() {
        let chat = ResearchChatClient(serverURL: serverURL, model: "m", maxTokens: 64,
                                      enableThinking: nil, transport: SendOnly(
                                        ResearchHTTPResponse(status: 200, body: Data())))
        #expect(!chat.streaming)
    }
}

@Suite("Web research stream assembler")
struct ResearchStreamAssemblerTests {
    private func data(_ json: String) -> String { "data: " + json }

    private func delta(_ delta: String, finish: String = "null") -> String {
        data(#"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#)
    }

    @Test func commentsEmptyLinesAndOtherFieldsAreSkipped() throws {
        let turn = try ResearchStreamAssembler.assemble(lines: [
            "", ": ping", delta(#"{"role":"assistant"}"#), "", "event: message", "id: 7",
            "retry: 1000", ":", delta(#"{"content":"A"}"#), ": ping",
            delta(#"{"content":"B"}"#), delta("{}", finish: #""stop""#), data("[DONE]"),
        ])
        #expect(turn.content == "AB")
        #expect(turn.finishReason == "stop")
    }

    @Test func nothingAfterDoneIsRead() throws {
        let turn = try ResearchStreamAssembler.assemble(lines: [
            delta(#"{"content":"A"}"#), delta("{}", finish: #""stop""#), data("[DONE]"),
            delta(#"{"content":"late"}"#), data(#"{"error":{"message":"late"}}"#),
        ])
        #expect(turn.content == "A")
    }

    @Test func dataWithoutASpaceAndWithACarriageReturnIsRead() throws {
        let turn = try ResearchStreamAssembler.assemble(lines: [
            #"data:{"choices":[{"index":0,"delta":{"content":"x"},"finish_reason":null}]}"# + "\r",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\r",
            "data: [DONE]\r",
        ])
        #expect(turn.content == "x")
        #expect(turn.finishReason == "stop")
    }

    @Test func aStreamWithAFinishReasonButNoDoneIsAccepted() throws {
        let turn = try ResearchStreamAssembler.assemble(lines: [
            delta(#"{"content":"A"}"#), delta("{}", finish: #""length""#),
        ])
        #expect(turn.content == "A")
        #expect(turn.finishReason == "length")
    }

    @Test func aStreamWithoutFinishReasonOrDoneIsMalformed() {
        #expect(throws: ResearchError.self) {
            _ = try ResearchStreamAssembler.assemble(lines: [delta(#"{"content":"A"}"#)])
        }
        #expect(throws: ResearchError.self) {
            _ = try ResearchStreamAssembler.assemble(lines: [])
        }
        // [DONE] alone has no choice either.
        #expect(throws: ResearchError.self) {
            _ = try ResearchStreamAssembler.assemble(lines: [data("[DONE]")])
        }
    }

    @Test func whiteSpaceInPiecesIsKeptExactly() throws {
        let turn = try ResearchStreamAssembler.assemble(lines: [
            delta(#"{"reasoning_content":" a "}"#), delta(#"{"reasoning_content":"\n"}"#),
            delta(#"{"content":""}"#), delta(#"{"content":"  b\n\n"}"#),
            delta("{}", finish: #""stop""#),
        ])
        #expect(turn.reasoning == " a \n")
        #expect(turn.content == "  b\n\n")
    }

    @Test func callsThatArriveInterleavedAreJoinedByIndex() throws {
        func piece(_ index: Int, id: String? = nil, name: String? = nil,
                   arguments: String) -> String {
            var fields = #""index":\#(index)"#
            if let id { fields += #","id":"\#(id)","type":"function""# }
            let function = (name.map { #""name":"\#($0)","# } ?? "") + #""arguments":"\#(arguments)""#
            return delta(#"{"tool_calls":[{\#(fields),"function":{\#(function)}}]}"#)
        }
        let turn = try ResearchStreamAssembler.assemble(lines: [
            piece(0, id: "a", name: "web_search", arguments: #"{\"query\":"#),
            piece(1, id: "b", name: "open_page", arguments: #"{\"url\":"#),
            piece(0, arguments: #"\"x\"}"#),
            piece(1, arguments: #"\"https://e.org/\"}"#),
            delta("{}", finish: #""tool_calls""#),
        ])
        #expect(turn.toolCalls == [
            ResearchToolCall(id: "a", name: "web_search", arguments: #"{"query":"x"}"#),
            ResearchToolCall(id: "b", name: "open_page", arguments: #"{"url":"https://e.org/"}"#),
        ])
    }

    @Test func aCallWithoutIdOrNameOrArgumentsIsMalformed() {
        func turn(_ call: String) throws -> ResearchAssistantTurn {
            try ResearchStreamAssembler.assemble(lines: [
                delta(#"{"tool_calls":[\#(call)]}"#), delta("{}", finish: #""tool_calls""#),
            ])
        }
        #expect(throws: ResearchError.self) {
            _ = try turn(#"{"index":0,"function":{"name":"web_search","arguments":"{}"}}"#)
        }
        #expect(throws: ResearchError.self) {
            _ = try turn(#"{"index":0,"id":"a","function":{"arguments":"{}"}}"#)
        }
        #expect(throws: ResearchError.self) {
            _ = try turn(#"{"index":0,"id":"a","function":{"name":"web_search"}}"#)
        }
        // An empty argument string is a string, as without streaming.
        #expect((try? turn(#"{"index":0,"id":"a","function":{"name":"web_search","arguments":""}}"#))?
            .toolCalls.first?.arguments == "")
    }

    @Test func errorStatusAndCodeAreDerived() {
        func error(_ json: String) -> ResearchError? {
            do {
                _ = try ResearchStreamAssembler.assemble(lines: [data(json), data("[DONE]")])
                return nil
            } catch {
                return error as? ResearchError
            }
        }
        // TUFF: the code is a string.
        #expect(error(#"{"error":{"message":"m","type":"invalid_request_error","code":"context_length_exceeded"}}"#)
            == .modelRequestFailed(status: 400, message: "m", code: "context_length_exceeded"))
        #expect(error(#"{"error":{"message":"m","type":"server_error","code":"internal_error"}}"#)
            == .modelRequestFailed(status: 500, message: "m", code: "internal_error"))
        #expect(error(#"{"error":{"message":"m","type":"x","code":"server_error"}}"#)
            == .modelRequestFailed(status: 500, message: "m", code: "server_error"))
        // llama.cpp: the code is a number, so the type names the error.
        #expect(error(#"{"error":{"code":400,"message":"m","type":"exceed_context_size_error"}}"#)
            == .modelRequestFailed(status: 400, message: "m", code: "exceed_context_size_error"))
        #expect(error(#"{"error":{"code":500,"message":"m","type":"server_error"}}"#)
            == .modelRequestFailed(status: 500, message: "m", code: "server_error"))
        // No message: the chunk itself, cut short.
        #expect(error(#"{"error":{"type":"x"}}"#)
            == .modelRequestFailed(status: 400, message: #"{"error":{"type":"x"}}"#, code: "x"))
    }

    @Test func anErrorDiscardsThePartialTurn() {
        #expect(throws: ResearchError.self) {
            _ = try ResearchStreamAssembler.assemble(lines: [
                delta(#"{"content":"partial"}"#),
                data(#"{"error":{"message":"m","type":"server_error","code":"internal_error"}}"#),
                data("[DONE]"),
            ])
        }
    }

    @Test func aChunkThatIsNotJSONIsMalformed() {
        #expect(throws: ResearchError.self) {
            _ = try ResearchStreamAssembler.assemble(lines: [data("{\"choices\":[{\"delta\":")])
        }
    }

    @Test func chunksWithoutChoicesOrWithNullsDoNotCrash() throws {
        let turn = try ResearchStreamAssembler.assemble(lines: [
            data("{}"), data("null"), data("[]"), data("7"), data(#"{"choices":[]}"#),
            data(#"{"choices":[null]}"#), data(#"{"choices":[{}]}"#),
            data(#"{"choices":[{"index":0,"delta":null,"finish_reason":null}],"usage":null}"#),
            data(#"{"choices":[{"index":0,"delta":{"content":null,"tool_calls":null,"reasoning_content":null},"finish_reason":null}]}"#),
            data(#"{"choices":[{"index":0,"delta":{"tool_calls":[]},"finish_reason":null}]}"#),
            data(#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}],"model":null,"error":null}"#),
            data(#"{"choices":[],"usage":{"prompt_tokens":"many"}}"#),
        ])
        #expect(turn.content == "ok")
        #expect(turn.promptTokens == nil)
        #expect(turn.model == nil)
    }
}

@Suite("Web research line splitting")
struct ResearchLineSplittingTests {
    @Test func linesAreSplitAtServerSentEventLineEndsOnly() async throws {
        let body = "a\r\nb\n\nc\rd\u{2028}e\u{85}f"
        let lines = try await collect(ResearchHTTPLineResponse(status: 200, body: Data(body.utf8)))
        #expect(lines == ["a", "b", "", "c", "d\u{2028}e\u{85}f"])
        #expect(try await collect(ResearchHTTPLineResponse(status: 200, body: Data())) == [])
        #expect(try await collect(ResearchHTTPLineResponse(status: 200, body: Data("x\n".utf8))) == ["x"])
    }

    @Test func aTransportWithOnlySendStillStreams() async throws {
        let transport = SendOnly(ResearchHTTPResponse(status: 201, body: Data("data: 1\n\ndata: 2\n".utf8)))
        let response = try await transport.sendStreaming(
            method: "POST", url: serverURL, body: nil, timeout: 5)
        #expect(response.status == 201)
        #expect(try await collect(response) == ["data: 1", "", "data: 2"])
    }
}
