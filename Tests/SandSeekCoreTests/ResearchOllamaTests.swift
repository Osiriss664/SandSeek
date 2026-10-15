import Foundation
import Testing
@testable import SandSeekCore

// Ollama's native chat API. The stream fixtures in Tests/Fixtures/streams
// (ollama-*.ndjson) are written by hand after Ollama's own types (api/types.go:
// ChatResponse, Message, ToolCall) and routes (server/routes.go): one JSON
// object per line, text and reasoning in `message.content` and
// `message.thinking`, whole tool calls with an `id` and an object for
// `arguments`, a last line with `done: true`, `done_reason` and
// `prompt_eval_count`, and an error inside the stream as `{"error":"..."}`.
// They are not recordings of a real server.

private let ollamaURL = URL(string: "http://127.0.0.1:11434")!

private enum OllamaFixture {
    /// `Tests/Fixtures/streams`, found from this file's place in the package.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SandSeekCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/streams")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name + ".ndjson"))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// The lines as the production splitter gives them.
    static func lines(_ name: String) throws -> [String] {
        var buffer = SSELineBuffer()
        var lines = buffer.read(contentsOf: try data(name))
        if let rest = buffer.finish() { lines.append(rest) }
        return lines
    }
}

/// Answers by method and URL from a handler, and remembers every request
/// with what it carried in the `Authorization` slot. A streamed request is
/// answered with the handler's body, cut into lines.
private final class OllamaFake: ResearchHTTPTransport, @unchecked Sendable {
    struct Seen: Equatable {
        let method: String
        let path: String
        let authorization: String?
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Seen] = []
    private let handler: @Sendable (String, URL) throws -> ResearchHTTPResponse

    init(_ handler: @escaping @Sendable (String, URL) throws -> ResearchHTTPResponse) {
        self.handler = handler
    }

    var seen: [Seen] { lock.withLock { recorded } }
    var paths: [String] { seen.map(\.path) }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: nil, authorization: nil)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse {
        lock.withLock {
            recorded.append(Seen(
                method: method, path: url.path, authorization: authorization,
                body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
        }
        return try handler(method, url)
    }

    func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                       authorization: String?) async throws -> ResearchHTTPLineResponse {
        let response = try await send(
            method: method, url: url, body: body, timeout: timeout, authorization: authorization)
        return ResearchHTTPLineResponse(status: response.status, body: response.body)
    }

    /// Ollama as `GET /api/version` shows it, and nothing else.
    static func version(_ version: String = "0.40.2") -> OllamaFake {
        OllamaFake { _, url in
            url.path == "/api/version" ? ok(#"{"version":"\#(version)"}"#) : status(404)
        }
    }
}

private func ok(_ json: String) -> ResearchHTTPResponse {
    ResearchHTTPResponse(status: 200, body: Data(json.utf8))
}

private func status(_ code: Int, error: String? = nil) -> ResearchHTTPResponse {
    let body = error.map { #"{"error":"\#($0)"}"# } ?? ""
    return ResearchHTTPResponse(status: code, body: Data(body.utf8))
}

private func ollamaClient(_ transport: any ResearchHTTPTransport,
                          streaming: Bool = true,
                          enableThinking: Bool? = nil,
                          contextTokens: Int? = 32_768,
                          serverURL: URL = ollamaURL,
                          authorization: String? = nil) -> ResearchChatClient {
    ResearchChatClient(serverURL: serverURL, model: "qwen3:8b", maxTokens: 512,
                       enableThinking: enableThinking, streaming: streaming,
                       authorization: authorization, kind: .ollama,
                       contextTokens: contextTokens, transport: transport)
}

private let userMessage: [ResearchJSON] = [
    .object(["role": .string("user"), "content": .string("Hallo")]),
]

private func complete(_ client: ResearchChatClient) async throws -> ResearchAssistantTurn {
    try await client.complete(messages: userMessage, tools: [])
}

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

private let searchTool: ResearchJSON = .object([
    "type": .string("function"),
    "function": .object([
        "name": .string("web_search"),
        "description": .string("Search the web."),
        "parameters": .object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
        ]),
    ]),
])

// MARK: - The request

@Suite("Ollama chat request")
struct ResearchOllamaRequestTests {
    /// A conversation as the loop keeps it: OpenAI-style, with a tool call
    /// whose arguments are a JSON string and reasoning in `reasoning_content`.
    private let conversation: [ResearchJSON] = [
        .object(["role": .string("system"), "content": .string("You research.")]),
        .object(["role": .string("user"), "content": .string("Wie funktioniert eine Wärmepumpe?")]),
        .object([
            "role": .string("assistant"),
            "tool_calls": .array([.object([
                "id": .string("call_k3x9q2ab"),
                "type": .string("function"),
                "function": .object([
                    "name": .string("web_search"),
                    "arguments": .string(#"{"query":"Wärmepumpe"}"#),
                ]),
            ])]),
            "reasoning_content": .string("I should search first.\n"),
        ]),
        .object([
            "role": .string("tool"),
            "tool_call_id": .string("call_k3x9q2ab"),
            "content": .string("[1] Result"),
        ]),
        .object([
            "role": .string("assistant"),
            "content": .string("Eine Antwort."),
            "reasoning_content": .string("Done."),
        ]),
    ]

    private func makeBody(_ client: ResearchChatClient,
                      toolUse: ResearchToolUse = .allowed,
                      thinking: Bool? = nil) throws -> [String: ResearchJSON] {
        try #require(client.requestBody(
            messages: conversation, tools: [searchTool], toolUse: toolUse,
            thinking: thinking).objectValue)
    }

    @Test func theBodyHasOllamasFieldsAndNoneOfTUFFs() throws {
        let sent = try makeBody(ollamaClient(OllamaFake.version()))
        #expect(sent["model"] == ResearchJSON.string("qwen3:8b"))
        #expect(sent["stream"] == ResearchJSON.bool(true))
        #expect(sent["truncate"] == ResearchJSON.bool(false))
        #expect(sent["shift"] == ResearchJSON.bool(false))
        let options = try #require(sent["options"]?.objectValue)
        #expect(options["num_ctx"] == ResearchJSON.integer(32_768))
        #expect(options["num_predict"] == ResearchJSON.integer(512))
        #expect(sent["tools"]?.arrayValue == [searchTool])
        #expect(sent["messages"]?.arrayValue?.count == 5)
        for key in ["enable_thinking", "preserve_thinking", "stream_options", "tool_choice",
                    "max_tokens", "think"] {
            #expect(sent[key] == nil, "\(key) must not be sent")
        }
    }

    @Test func streamFollowsTheClientAndAnUnknownWindowIsLeftToTheServer() throws {
        let plain = try makeBody(ollamaClient(OllamaFake.version(), streaming: false, contextTokens: nil))
        #expect(plain["stream"] == ResearchJSON.bool(false))
        let options = try #require(plain["options"]?.objectValue)
        #expect(options["num_ctx"] == nil)
        #expect(options["num_predict"] == ResearchJSON.integer(512))
    }

    @Test func toolCallArgumentsBecomeAnObjectAndTheIdStays() throws {
        let messages = try #require(try makeBody(ollamaClient(OllamaFake.version()))["messages"]?.arrayValue)
        let assistant = messages[2]
        #expect(assistant["role"] == ResearchJSON.string("assistant"))
        // No text: an empty string, which Ollama's message type needs.
        #expect(assistant["content"] == ResearchJSON.string(""))
        let call = try #require(assistant["tool_calls"]?.arrayValue?.first)
        #expect(call["id"] == ResearchJSON.string("call_k3x9q2ab"))
        #expect(call["function"]?["name"] == ResearchJSON.string("web_search"))
        #expect(call["function"]?["index"] == ResearchJSON.integer(0))
        #expect(call["function"]?["arguments"]
            == ResearchJSON.object(["query": .string("Wärmepumpe")]))
        // The OpenAI-style `type` is not part of Ollama's tool call.
        #expect(call["type"] == nil)
    }

    @Test func aToolResultKeepsItsCallIdAndGetsTheToolsName() throws {
        let messages = try #require(try makeBody(ollamaClient(OllamaFake.version()))["messages"]?.arrayValue)
        let result = messages[3]
        #expect(result["role"] == ResearchJSON.string("tool"))
        #expect(result["tool_call_id"] == ResearchJSON.string("call_k3x9q2ab"))
        #expect(result["tool_name"] == ResearchJSON.string("web_search"))
        #expect(result["content"] == ResearchJSON.string("[1] Result"))
    }

    @Test func aToolResultWithoutAKnownCallHasNoToolName() {
        let orphan: [ResearchJSON] = [
            .object(["role": .string("tool"), "tool_call_id": .string("call_x"),
                     "content": .string("r")]),
        ]
        let sent = ResearchOllama.messages(from: orphan)
        #expect(sent[0]["tool_name"] == nil)
        #expect(sent[0]["tool_call_id"] == ResearchJSON.string("call_x"))
    }

    @Test func earlierReasoningBecomesThinking() throws {
        let messages = try #require(try makeBody(ollamaClient(OllamaFake.version()))["messages"]?.arrayValue)
        #expect(messages[2]["thinking"] == ResearchJSON.string("I should search first.\n"))
        #expect(messages[2]["reasoning_content"] == nil)
        #expect(messages[4]["thinking"] == ResearchJSON.string("Done."))
        #expect(messages[4]["reasoning_content"] == nil)
        #expect(messages[4]["content"] == ResearchJSON.string("Eine Antwort."))
        // System and user messages are passed on as they are.
        #expect(messages[0] == conversation[0])
        #expect(messages[1] == conversation[1])
    }

    @Test func argumentsThatAreNotAnObjectBecomeTheEmptyObject() {
        #expect(ResearchOllama.argumentsObject(.string("not json")) == .object([:]))
        #expect(ResearchOllama.argumentsObject(.string("[1]")) == .object([:]))
        #expect(ResearchOllama.argumentsObject(nil) == .object([:]))
        #expect(ResearchOllama.argumentsObject(.string(#"{"a":1}"#))
            == .object(["a": .integer(1)]))
    }

    @Test func noToolsAreSentWhenTheRequestMustNotCallThem() throws {
        let client = ollamaClient(OllamaFake.version())
        #expect(try makeBody(client, toolUse: .off)["tools"] == nil)
        // "Answer now" keeps the tools: Ollama has no tool_choice to say none.
        #expect(try makeBody(client, toolUse: .discouraged)["tools"]?.arrayValue == [searchTool])
        #expect(try makeBody(client, toolUse: .allowed)["tools"]?.arrayValue == [searchTool])
        // Nothing to send when the loop has no tools.
        let bare = try #require(client.requestBody(
            messages: userMessage, tools: [], toolUse: .allowed).objectValue)
        #expect(bare["tools"] == nil)
    }

    @Test func thinkIsLeftOutUnlessReasoningIsAskedFor() throws {
        #expect(try makeBody(ollamaClient(OllamaFake.version()))["think"] == nil)
        #expect(try makeBody(ollamaClient(OllamaFake.version(), enableThinking: true))["think"]
            == ResearchJSON.bool(true))
        #expect(try makeBody(ollamaClient(OllamaFake.version(), enableThinking: false))["think"]
            == ResearchJSON.bool(false))
        // A request's own choice wins over the client's.
        #expect(try makeBody(ollamaClient(OllamaFake.version(), enableThinking: true),
                         thinking: false)["think"] == ResearchJSON.bool(false))
        #expect(try makeBody(ollamaClient(OllamaFake.version()), thinking: true)["think"]
            == ResearchJSON.bool(true))
    }

    @Test func theRequestGoesToApiChatAndCarriesNoKey() async throws {
        let fake = OllamaFake { _, _ in
            ok(#"{"model":"qwen3:8b","message":{"role":"assistant","content":"Hi"},"done":true,"done_reason":"stop"}"#)
        }
        let client = ollamaClient(fake, streaming: false, authorization: "Bearer secret")
        #expect(client.endpoint.absoluteString == "http://127.0.0.1:11434/api/chat")
        _ = try await complete(client)
        let streaming = ollamaClient(fake, streaming: true, authorization: "Bearer secret")
        _ = try await complete(streaming)
        #expect(fake.paths == ["/api/chat", "/api/chat"])
        // A key given by mistake is never sent to Ollama.
        #expect(fake.seen.allSatisfy { $0.authorization == nil })
        #expect(!fake.seen.contains { $0.body.contains("secret") })
        // The address may end in /v1, as for the other servers.
        let withV1 = ollamaClient(fake, serverURL: URL(string: "http://127.0.0.1:11434/v1")!)
        #expect(withV1.endpoint.absoluteString == "http://127.0.0.1:11434/api/chat")
    }

    @Test func theBodyThatIsSentIsTheOneBuilt() async throws {
        let fake = OllamaFake { _, _ in
            ok(#"{"model":"qwen3:8b","message":{"role":"assistant","content":"Hi"},"done":true}"#)
        }
        _ = try await ollamaClient(fake, streaming: false, enableThinking: true)
            .complete(messages: userMessage, tools: [searchTool], toolUse: .off)
        let sent = try #require(fake.seen.first?.body)
        let object = try #require(try ResearchJSON.decode(Data(sent.utf8)).objectValue)
        #expect(object["think"] == ResearchJSON.bool(true))
        #expect(object["tools"] == nil)
        #expect(object["options"]?["num_ctx"] == ResearchJSON.integer(32_768))
    }

    @Test func ollamaListsNoContextWindows() async {
        let fake = OllamaFake.version()
        #expect(await ollamaClient(fake).listedModels().isEmpty)
        #expect(fake.seen.isEmpty)
    }
}

// MARK: - A reply without streaming

@Suite("Ollama reply without streaming")
struct ResearchOllamaPlainReplyTests {
    @Test func aTextReplyBecomesATurn() async throws {
        let fake = OllamaFake { _, _ in
            ok(#"{"model":"qwen3:8b","created_at":"2026-10-15T09:30:01Z","message":{"role":"assistant","content":"Eine Antwort.","thinking":"Hmm."},"done":true,"done_reason":"stop","total_duration":1,"prompt_eval_count":321,"eval_count":9}"#)
        }
        let turn = try await complete(ollamaClient(fake, streaming: false))
        #expect(turn.content == "Eine Antwort.")
        #expect(turn.reasoning == "Hmm.")
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.finishReason == "stop")
        #expect(turn.promptTokens == 321)
        #expect(turn.model == "qwen3:8b")
    }

    @Test func toolCallsKeepTheirIdAndTheirArgumentsAsAnObjectString() async throws {
        let fake = OllamaFake { _, _ in
            ok(#"{"model":"qwen3:8b","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_a1","function":{"index":0,"name":"web_search","arguments":{"query":"x","n":3}}}]},"done":true,"done_reason":"stop","prompt_eval_count":50}"#)
        }
        let turn = try await complete(ollamaClient(fake, streaming: false))
        #expect(turn.toolCalls == [
            ResearchToolCall(id: "call_a1", name: "web_search", arguments: #"{"n":3,"query":"x"}"#),
        ])
        // The OpenAI-style reply says "tool_calls", and so does this one, so
        // the loop acts the same. No text with the calls: no content.
        #expect(turn.finishReason == "tool_calls")
        #expect(turn.content == nil)
        #expect(turn.reasoning == nil)
    }

    @Test func aCallWithoutAnIdGetsOneAndTheNumbersGoOn() async throws {
        let fake = OllamaFake { _, _ in
            ok(#"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"open_page","arguments":{"url":"https://example.org/"}}}]},"done":true}"#)
        }
        let client = ollamaClient(fake, streaming: false)
        let first = try await complete(client)
        let second = try await complete(client)
        #expect(first.toolCalls.map(\.id) == ["call_1"])
        #expect(second.toolCalls.map(\.id) == ["call_2"])
        #expect(first.toolCalls.first?.arguments == #"{"url":"https://example.org/"}"#)
    }

    @Test func aToolCallWithoutANameIsMalformed() async {
        let fake = OllamaFake { _, _ in
            ok(#"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"id":"c","function":{"arguments":{}}}]},"done":true}"#)
        }
        let error = await failure(ollamaClient(fake, streaming: false))
        guard case .malformedModelReply? = error else {
            Issue.record("expected malformedModelReply, got \(String(describing: error))")
            return
        }
    }

    @Test func aReplyThatIsNotAnObjectIsMalformed() async {
        for body in ["[1]", "<html>", ""] {
            let fake = OllamaFake { _, _ in ok(body) }
            let error = await failure(ollamaClient(fake, streaming: false))
            guard case .malformedModelReply? = error else {
                Issue.record("expected malformedModelReply for \(body), got \(String(describing: error))")
                continue
            }
        }
    }

    @Test func anErrorInAnAnswerWithStatus200IsARefusal() async {
        let fake = OllamaFake { _, _ in ok(#"{"error":"something broke"}"#) }
        #expect(await failure(ollamaClient(fake, streaming: false))
            == .modelRequestFailed(status: 500, message: "something broke", code: nil))
    }
}

// MARK: - The stream

@Suite("Ollama stream")
struct ResearchOllamaStreamTests {
    @Test func textAndReasoningAreJoinedExactlyAsTheyArrive() throws {
        let turn = try ResearchOllamaStreamAssembler.assemble(lines: try OllamaFixture.lines("ollama-answer"))
        #expect(turn.content == "\n\nEine Wärmepumpe nutzt Umgebungswärme. [1]\n")
        #expect(turn.reasoning == "Okay, the user wants a short answer.\n")
        #expect(turn.toolCalls.isEmpty)
        #expect(turn.finishReason == "stop")
        #expect(turn.promptTokens == 1834)
        #expect(turn.model == "qwen3:8b")
    }

    @Test func theClientGivesTheSameTurnWhateverThePiecesAreCutAt() async throws {
        let bytes = try OllamaFixture.data("ollama-answer")
        let expected = try ResearchOllamaStreamAssembler.assemble(lines: try OllamaFixture.lines("ollama-answer"))
        // Cut anywhere, also inside the two bytes of "ä".
        for size in [1, 7, 64, bytes.count] {
            var chunks: [Data] = []
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = bytes.index(start, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
                chunks.append(bytes[start..<end])
                start = end
            }
            let response = ResearchHTTPLineResponse(status: 200, chunks: chunks)
            let turn = try await ResearchOllamaStreamAssembler.assemble(response.lines)
            #expect(turn == expected, "pieces of \(size) bytes")
        }
    }

    @Test func theStreamedTurnEqualsTheTurnOfTheSameMessageWithoutStreaming() async throws {
        let streamed = try await complete(ollamaClient(OllamaFake { _, _ in
            ResearchHTTPResponse(status: 200, body: try OllamaFixture.data("ollama-answer"))
        }))
        let whole = #"{"model":"qwen3:8b","message":{"role":"assistant","content":"\n\nEine Wärmepumpe nutzt Umgebungswärme. [1]\n","thinking":"Okay, the user wants a short answer.\n"},"done":true,"done_reason":"stop","prompt_eval_count":1834}"#
        let plain = try await complete(ollamaClient(OllamaFake { _, _ in ok(whole) }, streaming: false))
        #expect(streamed == plain)
    }

    @Test func wholeToolCallsInAnyLineAreCollected() throws {
        let turn = try ResearchOllamaStreamAssembler.assemble(lines: try OllamaFixture.lines("ollama-tool-call"))
        #expect(turn.toolCalls == [
            ResearchToolCall(id: "call_k3x9q2ab", name: "web_search",
                             arguments: #"{"query":"Wärmepumpe Förderung 2026"}"#),
            ResearchToolCall(id: "call_p7m1d5ze", name: "open_page",
                             arguments: #"{"max_chars":3000,"url":"https://example.org/a"}"#),
        ])
        #expect(turn.finishReason == "tool_calls")
        #expect(turn.content == nil)
        #expect(turn.reasoning == "I should search first.\n")
        #expect(turn.promptTokens == 2048)
    }

    @Test func callsWithoutAnIdAreNumberedFromTheGivenNumber() throws {
        let lines = [
            #"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"a","arguments":{}}}]},"done":false}"#,
            #"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"b","arguments":{"k":1}}}]},"done":false}"#,
            #"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
        ]
        let turn = try ResearchOllamaStreamAssembler.assemble(lines: lines, firstCallNumber: 5)
        #expect(turn.toolCalls.map(\.id) == ["call_5", "call_6"])
        #expect(turn.toolCalls.map(\.arguments) == ["{}", #"{"k":1}"#])
    }

    @Test func aTurnThatReachedTheTokenLimitSaysLength() throws {
        let turn = try ResearchOllamaStreamAssembler.assemble(lines: try OllamaFixture.lines("ollama-length"))
        #expect(turn.finishReason == "length")
        #expect(turn.content == "")
        #expect(turn.reasoning == "Let me think about this for a long time")
        #expect(turn.promptTokens == 900)
    }

    @Test func anErrorInTheStreamIsARefusalAndTheTextBeforeItIsDropped() async {
        let fake = OllamaFake { _, _ in
            ResearchHTTPResponse(status: 200, body: try OllamaFixture.data("ollama-error-in-stream"))
        }
        #expect(await failure(ollamaClient(fake)) == .modelRequestFailed(
            status: 500,
            message: "model runner has unexpectedly stopped, this may be due to resource limitations or an internal error",
            code: nil))
    }

    @Test func anErrorThatSaysThePromptIsTooLongHasTheContextCode() throws {
        let lines = [
            #"{"error":"the prompt is longer than the context length currently available to the model; shorten the prompt"}"#,
        ]
        do {
            _ = try ResearchOllamaStreamAssembler.assemble(lines: lines)
            Issue.record("expected an error")
        } catch let error as ResearchError {
            guard case .modelRequestFailed(let status, _, let code) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(status == 400)
            #expect(code == "context_length_exceeded")
        }
    }

    @Test func aStreamThatEndsWithoutDoneIsCutOff() async {
        let fake = OllamaFake { _, _ in
            ResearchHTTPResponse(status: 200, body: try OllamaFixture.data("ollama-cut-off"))
        }
        let error = await failure(ollamaClient(fake))
        guard case .malformedModelReply(let message)? = error else {
            Issue.record("expected malformedModelReply, got \(String(describing: error))")
            return
        }
        #expect(message.contains("done"), "\(message)")
        // An empty stream holds no message at all.
        #expect(throws: ResearchError.self) {
            _ = try ResearchOllamaStreamAssembler.assemble(lines: [])
        }
    }

    @Test func aLineThatIsNotJSONIsMalformed() {
        for line in ["data: {\"x\":1}", "<html>", "[1]", "{broken"] {
            #expect(throws: ResearchError.self, "\(line)") {
                _ = try ResearchOllamaStreamAssembler.assemble(lines: [line])
            }
        }
    }

    @Test func emptyLinesAndCarriageReturnsAreSkipped() throws {
        let lines = [
            "",
            #"{"model":"m","message":{"role":"assistant","content":"Ein"},"done":false}"# + "\r",
            "   ",
            #"{"model":"m","message":{"role":"assistant","content":"s"},"done":true,"done_reason":"stop"}"# + "\r",
        ]
        let turn = try ResearchOllamaStreamAssembler.assemble(lines: lines)
        #expect(turn.content == "Eins")
    }

    @Test func nothingAfterDoneChangesTheTurn() throws {
        var assembler = ResearchOllamaStreamAssembler()
        let first = try assembler.feed(#"{"model":"m","message":{"role":"assistant","content":"A"},"done":false}"#)
        #expect(first == false)
        let last = try assembler.feed(#"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#)
        #expect(last)
        #expect(assembler.isDone)
        // Even a line that would be an error is not read any more.
        let late = try assembler.feed(#"{"error":"late"}"#)
        #expect(late)
        let turn = try assembler.finish()
        #expect(turn.content == "A")
    }

    @Test func aTimeLimitInTheMiddleOfTheStreamIsATimeout() async {
        final class Failing: ResearchHTTPTransport, @unchecked Sendable {
            func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
                ResearchHTTPResponse(status: 500, body: Data())
            }

            func sendStreaming(method: String, url: URL, body: Data?,
                               timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
                let lines = AsyncThrowingStream<String, any Error> { continuation in
                    continuation.yield(#"{"model":"m","message":{"role":"assistant","content":"Ein"},"done":false}"#)
                    continuation.finish(throwing: URLError(.timedOut))
                }
                return ResearchHTTPLineResponse(status: 200, lines: lines)
            }
        }
        #expect(await failure(ollamaClient(Failing())) == .modelTimedOut)
    }
}

// MARK: - Refusals

@Suite("Ollama refusals")
struct ResearchOllamaRefusalTests {
    @Test func theErrorOfARefusedRequestIsAPlainString() async {
        for streaming in [false, true] {
            let thinking = OllamaFake { _, _ in
                status(400, error: #"\"gemma\" does not support thinking"#)
            }
            #expect(await failure(ollamaClient(thinking, streaming: streaming))
                == .modelRequestFailed(status: 400, message: "\"gemma\" does not support thinking",
                                       code: nil), "streaming \(streaming)")
            let missing = OllamaFake { _, _ in status(404, error: "model 'x' not found") }
            #expect(await failure(ollamaClient(missing, streaming: streaming))
                == .modelRequestFailed(status: 404, message: "model 'x' not found", code: nil))
        }
    }

    @Test func aBodyThatIsNotJSONIsShownAsItIs() async {
        let fake = OllamaFake { _, _ in
            ResearchHTTPResponse(status: 502, body: Data("Bad Gateway".utf8))
        }
        #expect(await failure(ollamaClient(fake)) == .modelRequestFailed(
            status: 502, message: "Bad Gateway", code: nil))
    }

    @Test func aPromptThatDoesNotFitHasTheContextCodeSoTheLoopShortensIt() async {
        let message = "the prompt is longer than the context length currently available to the model; shorten the prompt, adjust the context length in settings, or use a model with a longer context length"
        for streaming in [false, true] {
            let fake = OllamaFake { _, _ in status(400, error: message) }
            #expect(await failure(ollamaClient(fake, streaming: streaming))
                == .modelRequestFailed(status: 400, message: message, code: "context_length_exceeded"))
        }
        #expect(ResearchOllama.isContextOverflow("the input length exceeds the context length"))
        #expect(!ResearchOllama.isContextOverflow("model runner has unexpectedly stopped"))
        #expect(!ResearchOllama.isContextOverflow("\"x\" does not support thinking"))
    }

    @Test func aRedirectIsRefusedAndNotRead() async {
        for streaming in [false, true] {
            let fake = OllamaFake { _, _ in status(302) }
            #expect(await failure(ollamaClient(fake, streaming: streaming))
                == .redirectRefused(status: 302))
        }
    }

    @Test func aServerThatIsGoneIsUnavailable() async {
        let fake = OllamaFake { _, _ in throw URLError(.cannotConnectToHost) }
        for streaming in [false, true] {
            let error = await failure(ollamaClient(fake, streaming: streaming))
            guard case .modelUnavailable? = error else {
                Issue.record("expected modelUnavailable, got \(String(describing: error))")
                continue
            }
        }
        let slow = OllamaFake { _, _ in throw URLError(.timedOut) }
        #expect(await failure(ollamaClient(slow, streaming: false)) == .modelTimedOut)
        #expect(await failure(ollamaClient(slow, streaming: true)) == .modelTimedOut)
    }
}

// MARK: - Detection

@Suite("Ollama detection")
struct ResearchOllamaDetectionTests {
    @Test func theVersionRouteTellsOllama() async {
        #expect(await ResearchServerConnection.probeOllama(
            serverURL: ollamaURL, transport: OllamaFake.version("0.40.2")) == .ollama(version: "0.40.2"))
        #expect(await ResearchServerConnection.probeOllama(
            serverURL: URL(string: "http://127.0.0.1:11434/v1")!,
            transport: OllamaFake.version()) == .ollama(version: "0.40.2"))
        for response in [ResearchHTTPResponse(status: 404, body: Data()),
                         ok("<html>"), ok("[1]"), ok(#"{"version":2}"#), ok(#"{"name":"x"}"#)] {
            let probe = await ResearchServerConnection.probeOllama(
                serverURL: ollamaURL, transport: OllamaFake { _, _ in response })
            #expect(probe == .other(status: response.status), "\(response)")
        }
        let silent = OllamaFake { _, _ in throw URLError(.cannotConnectToHost) }
        guard case .unreachable = await ResearchServerConnection.probeOllama(
            serverURL: ollamaURL, transport: silent) else {
            Issue.record("expected unreachable")
            return
        }
    }

    @Test func namingOllamaAsksOnlyTheVersionRoute() async throws {
        let fake = OllamaFake.version("0.40.2")
        let connection = try await ResearchServerConnection.establish(
            choice: .ollama, stream: nil, serverURL: ollamaURL, transport: fake)
        #expect(connection == ResearchServerConnection(kind: .ollama, version: "0.40.2", streaming: true))
        #expect(connection.progressLine == "server: Ollama 0.40.2, streaming")
        #expect(fake.paths == ["/api/version"])
        let off = try await ResearchServerConnection.establish(
            choice: .ollama, stream: false, serverURL: ollamaURL, transport: fake)
        #expect(!off.streaming)
        #expect(off.progressLine == "server: Ollama 0.40.2, no streaming")
    }

    @Test func theProgressLineNamesTheContextWindow() {
        let connection = ResearchServerConnection(kind: .ollama, version: "0.40.2", streaming: true)
            .withContextTokens(32_768)
        #expect(connection.contextTokens == 32_768)
        #expect(connection.progressLine == "server: Ollama 0.40.2, streaming, context 32768 tokens")
        #expect(connection.withContextTokens(nil).progressLine == "server: Ollama 0.40.2, streaming")
    }

    @Test func autoFindsOllamaWhenTUFFsStatusRouteIsNotThere() async throws {
        let fake = OllamaFake.version("0.40.2")
        let connection = try await ResearchServerConnection.establish(
            choice: .auto, stream: nil, serverURL: ollamaURL, transport: fake)
        #expect(connection == ResearchServerConnection(kind: .ollama, version: "0.40.2", streaming: true))
        #expect(fake.paths == ["/tuff/v1/status", "/api/version"])
        let plain = try await ResearchServerConnection.establish(
            choice: .auto, stream: false, serverURL: ollamaURL, transport: fake)
        #expect(!plain.streaming)
    }

    @Test func autoStillPrefersTUFFWhenItsRouteAnswers() async throws {
        let both = OllamaFake { _, url in
            url.path == "/tuff/v1/status"
                ? ok(#"{"version":"8.3.1","mode":"router"}"#)
                : ok(#"{"version":"0.40.2"}"#)
        }
        let connection = try await ResearchServerConnection.establish(
            choice: .auto, stream: nil, serverURL: ollamaURL, transport: both)
        #expect(connection.kind == .tuff)
        #expect(connection.version == "8.3.1")
    }

    @Test func autoRefusesAnUnknownServerAndNamesBothWaysOut() async {
        let unknown = OllamaFake { _, _ in ok("<html>") }
        do {
            _ = try await ResearchServerConnection.establish(
                choice: .auto, stream: nil, serverURL: ollamaURL, transport: unknown)
            Issue.record("expected the server to be refused")
        } catch let error as ResearchError {
            let text = error.description
            #expect(text.contains("--server-type ollama"), "\(text)")
            #expect(text.contains("--server-type llamacpp"), "\(text)")
            #expect(text.contains("--server-type tuff"), "\(text)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aServerThatDoesNotAnswerIsUnreachable() async {
        let silent = OllamaFake { _, _ in throw URLError(.cannotConnectToHost) }
        for choice in [ResearchServerChoice.ollama, .auto] {
            do {
                _ = try await ResearchServerConnection.establish(
                    choice: choice, stream: nil, serverURL: ollamaURL, transport: silent)
                Issue.record("expected an error for \(choice)")
            } catch ResearchError.modelUnavailable(_) {
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test func aRedirectIsRefusedForANamedOllama() async {
        let redirect = OllamaFake { _, _ in status(307) }
        do {
            _ = try await ResearchServerConnection.establish(
                choice: .ollama, stream: nil, serverURL: ollamaURL, transport: redirect)
            Issue.record("expected an error")
        } catch ResearchError.redirectRefused(let code) {
            #expect(code == 307)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aNamedOllamaThatAnswersAsSomethingElseIsAnError() async {
        let others = [OllamaFake { _, _ in status(404) }, OllamaFake { _, _ in ok("<html>") },
                      OllamaFake { _, url in
                          url.path == "/tuff/v1/status" ? ok(#"{"version":"8.3.1"}"#) : status(404)
                      }]
        for other in others {
            do {
                _ = try await ResearchServerConnection.establish(
                    choice: .ollama, stream: nil, serverURL: ollamaURL, transport: other)
                Issue.record("expected an error")
            } catch let error as ResearchError {
                guard case .invalidEndpoint(let text) = error else {
                    Issue.record("unexpected \(error)")
                    continue
                }
                #expect(text.contains("not Ollama"), "\(text)")
                #expect(text.contains("--server-type tuff"), "\(text)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }
}

// MARK: - The model and its context

@Suite("Ollama model and context")
struct ResearchOllamaModelTests {
    private func show(_ json: String) -> OllamaFake {
        OllamaFake { _, url in url.path == "/api/show" ? ok(json) : status(404) }
    }

    private let base = ResearchServerConnection(kind: .ollama, version: "0.40.2", streaming: true)

    private let qwen = #"{"capabilities":["completion","tools","thinking"],"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960,"qwen3.embedding_length":4096}}"#

    @Test func theContextIs32768OrTheTrainedMaximumWhenThatIsSmaller() {
        #expect(ResearchOllama.contextTokens(requested: nil, trained: 131_072) == 32_768)
        #expect(ResearchOllama.contextTokens(requested: nil, trained: 32_768) == 32_768)
        #expect(ResearchOllama.contextTokens(requested: nil, trained: 8_192) == 8_192)
        #expect(ResearchOllama.contextTokens(requested: nil, trained: nil) == 32_768)
    }

    @Test func theFlagSetsTheContextWhateverTheModelSays() {
        #expect(ResearchOllama.contextTokens(requested: 65_536, trained: 8_192) == 65_536)
        #expect(ResearchOllama.contextTokens(requested: 4_096, trained: 131_072) == 4_096)
        #expect(ResearchOllama.contextTokens(requested: 262_144, trained: nil) == 262_144)
    }

    @Test func showIsReadForCapabilitiesCloudAndTheTrainedContext() throws {
        let info = ResearchOllama.modelInfo(fromShow: try ResearchJSON.decode(Data(qwen.utf8)))
        #expect(info == ResearchOllama.ModelInfo(
            capabilities: ["completion", "tools", "thinking"], isCloud: false,
            trainedContextTokens: 40_960))
        #expect(info.canCallTools)
        // The architecture's own key wins over another key that ends in .context_length.
        let two = ResearchOllama.modelInfo(fromShow: try ResearchJSON.decode(Data(
            #"{"model_info":{"general.architecture":"gemma3","gemma3.context_length":131072,"vision.context_length":4096}}"#.utf8)))
        #expect(two.trainedContextTokens == 131_072)
        // Without a named architecture the smallest value is taken.
        let unnamed = ResearchOllama.modelInfo(fromShow: try ResearchJSON.decode(Data(
            #"{"model_info":{"a.context_length":8192,"b.context_length":4096}}"#.utf8)))
        #expect(unnamed.trainedContextTokens == 4_096)
        let none = ResearchOllama.modelInfo(fromShow: try ResearchJSON.decode(Data(
            #"{"model_info":{"general.architecture":"x"}}"#.utf8)))
        #expect(none.trainedContextTokens == nil)
        #expect(none.capabilities == nil)
        #expect(none.canCallTools)
        let cloud = ResearchOllama.modelInfo(fromShow: try ResearchJSON.decode(Data(
            #"{"remote_host":"https://ollama.com:443","capabilities":["completion"]}"#.utf8)))
        #expect(cloud.isCloud)
        #expect(!cloud.canCallTools)
    }

    @Test func prepareChoosesTheContextFromTheModelsMaximum() async throws {
        let fake = show(qwen)
        let prepared = try await ResearchOllama.prepare(
            base, model: "qwen3:8b", requestedContextTokens: nil, serverURL: ollamaURL, transport: fake)
        #expect(prepared.contextTokens == 32_768)
        #expect(prepared.kind == .ollama)
        #expect(prepared.version == "0.40.2")
        #expect(prepared.progressLine == "server: Ollama 0.40.2, streaming, context 32768 tokens")
        let request = try #require(fake.seen.first)
        #expect(fake.seen.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/api/show")
        #expect(request.authorization == nil)
        #expect(try ResearchJSON.decode(Data(request.body.utf8)) == .object(["model": .string("qwen3:8b")]))
    }

    @Test func aSmallTrainedMaximumLowersTheContext() async throws {
        let small = show(#"{"capabilities":["tools"],"model_info":{"general.architecture":"llama","llama.context_length":8192}}"#)
        let prepared = try await ResearchOllama.prepare(
            base, model: "tiny", requestedContextTokens: nil, serverURL: ollamaURL, transport: small)
        #expect(prepared.contextTokens == 8_192)
    }

    @Test func anUnknownMaximumGives32768AndTheFlagOverrides() async throws {
        let unknown = show(#"{"capabilities":["tools"],"model_info":{}}"#)
        #expect(try await ResearchOllama.prepare(
            base, model: "m", requestedContextTokens: nil, serverURL: ollamaURL,
            transport: unknown).contextTokens == 32_768)
        #expect(try await ResearchOllama.prepare(
            base, model: "m", requestedContextTokens: 65_536, serverURL: ollamaURL,
            transport: show(qwen)).contextTokens == 65_536)
    }

    @Test func aModelWithoutCapabilitiesInTheAnswerIsAllowed() async throws {
        let older = show(#"{"model_info":{"general.architecture":"llama","llama.context_length":4096}}"#)
        let prepared = try await ResearchOllama.prepare(
            base, model: "old", requestedContextTokens: nil, serverURL: ollamaURL, transport: older)
        #expect(prepared.contextTokens == 4_096)
    }

    @Test func aCloudNameIsRefusedBeforeAnyRequest() async {
        for name in ["gpt-oss:120b-cloud", "qwen3-coder:480b-cloud", "kimi-k2:cloud",
                     "KIMI-K2:CLOUD", " llama:Cloud "] {
            let fake = show(qwen)
            do {
                _ = try await ResearchOllama.prepare(
                    base, model: name, requestedContextTokens: nil, serverURL: ollamaURL,
                    transport: fake)
                Issue.record("expected \(name) to be refused")
            } catch ResearchError.invalidEndpoint(let text) {
                #expect(text.contains("SandSeek keeps your question on this Mac"), "\(text)")
                #expect(text.contains("is an Ollama cloud model that runs on ollama.com"), "\(text)")
                #expect(text.contains(name.trimmingCharacters(in: .whitespaces)), "\(text)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
            #expect(fake.seen.isEmpty, "\(name) must not reach the server")
        }
        #expect(ResearchOllama.isCloudModelName("a:cloud"))
        #expect(ResearchOllama.isCloudModelName("a:b-cloud"))
        #expect(!ResearchOllama.isCloudModelName("cloudy:7b"))
        #expect(!ResearchOllama.isCloudModelName("qwen3:8b"))
    }

    @Test func aModelThatOllamaRunsRemotelyIsRefused() async {
        let remote = show(#"{"remote_host":"https://ollama.com:443","remote_model":"gpt-oss:120b","capabilities":["completion","tools"],"model_info":{}}"#)
        do {
            _ = try await ResearchOllama.prepare(
                base, model: "my-alias", requestedContextTokens: nil, serverURL: ollamaURL,
                transport: remote)
            Issue.record("expected the model to be refused")
        } catch ResearchError.invalidEndpoint(let text) {
            #expect(text.contains("SandSeek keeps your question on this Mac; my-alias is an Ollama cloud model that runs on ollama.com"), "\(text)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aModelThatCannotCallToolsIsRefused() async {
        let plain = show(#"{"capabilities":["completion"],"model_info":{"general.architecture":"qwen2","qwen2.context_length":32768}}"#)
        do {
            _ = try await ResearchOllama.prepare(
                base, model: "qwen2.5-coder:1.5b-base", requestedContextTokens: nil,
                serverURL: ollamaURL, transport: plain)
            Issue.record("expected the model to be refused")
        } catch ResearchError.invalidEndpoint(let text) {
            #expect(text.contains("qwen2.5-coder:1.5b-base cannot call tools"), "\(text)")
            #expect(text.contains("completion"), "\(text)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func aModelThatIsNotInstalledSaysHowToGetIt() async {
        let missing = OllamaFake { _, _ in status(404, error: "model 'nope' not found") }
        do {
            _ = try await ResearchOllama.prepare(
                base, model: "nope:7b", requestedContextTokens: nil, serverURL: ollamaURL,
                transport: missing)
            Issue.record("expected an error")
        } catch ResearchError.invalidEndpoint(let text) {
            #expect(text.contains("nope:7b is not installed"), "\(text)")
            #expect(text.contains("ollama pull nope:7b"), "\(text)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func noModelOrTheDefaultIsRefusedBeforeAnyRequest() async {
        for name in ["default", "", "  "] {
            let fake = show(qwen)
            do {
                _ = try await ResearchOllama.prepare(
                    base, model: name, requestedContextTokens: nil, serverURL: ollamaURL,
                    transport: fake)
                Issue.record("expected an error for '\(name)'")
            } catch ResearchError.invalidEndpoint(let text) {
                #expect(text.contains("no default model"), "\(text)")
                #expect(text.contains("--model"), "\(text)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
            #expect(fake.seen.isEmpty)
        }
    }

    @Test func otherRefusalsAndFailuresOfShowAreReported() async {
        let busy = OllamaFake { _, _ in status(500, error: "boom") }
        do {
            _ = try await ResearchOllama.prepare(
                base, model: "m", requestedContextTokens: nil, serverURL: ollamaURL, transport: busy)
            Issue.record("expected an error")
        } catch ResearchError.modelRequestFailed(let code, let message, _) {
            #expect(code == 500)
            #expect(message == "boom")
        } catch {
            Issue.record("unexpected error \(error)")
        }
        let redirect = OllamaFake { _, _ in status(302) }
        do {
            _ = try await ResearchOllama.prepare(
                base, model: "m", requestedContextTokens: nil, serverURL: ollamaURL,
                transport: redirect)
            Issue.record("expected an error")
        } catch ResearchError.redirectRefused(let code) {
            #expect(code == 302)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        let gone = OllamaFake { _, _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await ResearchOllama.prepare(
                base, model: "m", requestedContextTokens: nil, serverURL: ollamaURL, transport: gone)
            Issue.record("expected an error")
        } catch ResearchError.modelUnavailable(_) {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func anotherKindOfServerIsLeftAloneWithoutARequest() async throws {
        let fake = show(qwen)
        let tuff = ResearchServerConnection(kind: .tuff, version: "8.3.1", streaming: true)
        let same = try await ResearchOllama.prepare(
            tuff, model: "default", requestedContextTokens: nil, serverURL: ollamaURL, transport: fake)
        #expect(same == tuff)
        #expect(fake.seen.isEmpty)
    }
}

// MARK: - Arguments

@Suite("Ollama arguments")
struct ResearchOllamaArgumentTests {
    private func parse(_ arguments: [String]) throws -> ResearchArguments {
        try ResearchArguments.parse(arguments, environment: [:])
    }

    @Test func serverTypeOllamaIsParsed() throws {
        let parsed = try parse(["q", "--server-type", "ollama", "--model", "qwen3:8b",
                                "--server", "http://127.0.0.1:11434"])
        #expect(parsed.serverType == .ollama)
        #expect(parsed.model == "qwen3:8b")
        #expect(parsed.serverURL.port == 11_434)
        #expect(parsed.contextTokens == nil)
        #expect(try parse(["q", "--server-type", "ollama", "--model", "m", "--stream", "off"])
            .stream == false)
        // auto may find Ollama, so the model is not checked at parse time.
        #expect(try parse(["q"]).serverType == .auto)
    }

    @Test func contextTokensIsParsedAndHasARange() throws {
        #expect(try parse(["q", "--server-type", "ollama", "--model", "m",
                           "--context-tokens", "65536"]).contextTokens == 65_536)
        #expect(try parse(["q", "--context-tokens", "4096"]).contextTokens == 4_096)
        #expect(try parse(["q", "--context-tokens", "262144"]).contextTokens == 262_144)
        for value in ["4095", "262145", "0", "-1", "abc", "32k"] {
            #expect(throws: ResearchArgumentError.self, "\(value)") {
                _ = try parse(["q", "--context-tokens", value])
            }
        }
        #expect(throws: ResearchArgumentError.self) { _ = try parse(["q", "--context-tokens"]) }
    }

    @Test func contextTokensIsOnlyForOllama() {
        for type in ["tuff", "llamacpp"] {
            #expect(throws: ResearchArgumentError.self, "\(type)") {
                _ = try parse(["q", "--server-type", type, "--context-tokens", "8192"])
            }
        }
        #expect(throws: ResearchArgumentError.self) {
            _ = try parse(["--replay-figures", "a.json", "--context-tokens", "8192"])
        }
    }

    @Test func ollamaNeedsAModelThatIsNotACloudModel() {
        #expect(throws: ResearchArgumentError.self) {
            _ = try parse(["q", "--server-type", "ollama"])
        }
        for name in ["gpt-oss:120b-cloud", "kimi-k2:cloud"] {
            do {
                _ = try parse(["q", "--server-type", "ollama", "--model", name])
                Issue.record("expected \(name) to be refused")
            } catch let error as ResearchArgumentError {
                #expect(error.description.contains("runs on ollama.com"), "\(error)")
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test func ollamaTakesNoKeyFile() {
        do {
            _ = try parse(["q", "--server-type", "ollama", "--model", "m",
                           "--api-key-file", "/tmp/key"])
            Issue.record("expected an error")
        } catch let error as ResearchArgumentError {
            #expect(error.description.contains("--api-key-file"), "\(error)")
            #expect(error.description.contains("no key"), "\(error)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func helpAndVersionNeedNoModel() throws {
        #expect(try parse(["--server-type", "ollama", "--help"]).showHelp)
        #expect(try parse(["--server-type", "ollama", "--version"]).showVersion)
    }

    @Test func theUsageDescribesOllama() {
        let usage = ResearchArguments.usage
        #expect(usage.contains("--server-type tuff|llamacpp|ollama|auto"))
        #expect(usage.contains("--context-tokens"))
        #expect(usage.contains("/api/version"))
        #expect(usage.contains("experimental"))
        #expect(usage.contains("OLLAMA_HOST=127.0.0.1:11434"))
        #expect(usage.contains("cloud"))
    }

    @Test func aBadServerTypeNamesOllamaAmongTheChoices() {
        do {
            _ = try parse(["q", "--server-type", "lmstudio"])
            Issue.record("expected an error")
        } catch let error as ResearchArgumentError {
            #expect(error.description.contains("ollama"), "\(error)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
