import Foundation
import Testing
@testable import SandSeekCore

// Real recordings of TUFF 8.3.1 (Tests/Fixtures/streams/*.sse, recorded with
// Scripts/record_stream.py on the Mac), run through the same
// code the client uses: the byte splitter (`SSELineBuffer`), the assembler
// (`ResearchStreamAssembler`) and `ResearchChatClient.complete`. The files
// are byte for byte what the server wrote: LF line ends, `: ping` comments,
// no edits. The expected values below were read off the files; where a test
// says "the same text as the file", the text is rebuilt from the file's own
// chunks with plain JSON decoding, apart from the assembler.

// MARK: the recordings

private enum Recording {
    /// `Tests/Fixtures/streams`, found from this file's place in the package.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SandSeekCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures/streams")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name + ".sse"))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    /// The lines as the splitter gives them (LF ends a line, a last line
    /// without LF is kept).
    static func lines(_ name: String) throws -> [String] {
        var buffer = SSELineBuffer()
        var lines = buffer.read(contentsOf: try data(name))
        if let rest = buffer.finish() { lines.append(rest) }
        return lines
    }

    /// What the file holds, read without the assembler: the JSON of each
    /// `data:` line that is not `[DONE]`.
    static func chunks(_ name: String) throws -> [[String: Any]] {
        try lines(name).compactMap { line in
            guard line.hasPrefix("data: {") else { return nil }
            let json = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
            return json as? [String: Any]
        }
    }

    private static func deltas(_ name: String, key: String) throws -> [String] {
        try chunks(name).compactMap { chunk in
            let choice = (chunk["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?[key] as? String
        }
    }

    static func contentPieces(_ name: String) throws -> [String] {
        try deltas(name, key: "content")
    }

    static func reasoningPieces(_ name: String) throws -> [String] {
        try deltas(name, key: "reasoning_content")
    }

    static let model = "qwen3.6-35b-a3b"
}

// MARK: the transport that plays a recording

/// Answers the chat endpoint with a recording: through `sendStreaming` in
/// pieces of `chunkSize` bytes (cut into lines by the production splitter),
/// or through `send` with the whole body.
private final class RecordingTransport: ResearchHTTPTransport, @unchecked Sendable {
    private let status: Int
    private let bytes: Data
    private let chunkSize: Int?

    init(_ bytes: Data, status: Int = 200, chunkSize: Int? = nil) {
        self.status = status
        self.bytes = bytes
        self.chunkSize = chunkSize
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        ResearchHTTPResponse(status: status, body: bytes)
    }

    func sendStreaming(method: String, url: URL, body: Data?,
                       timeout: TimeInterval?) async throws -> ResearchHTTPLineResponse {
        guard let size = chunkSize, size > 0 else {
            return ResearchHTTPLineResponse(status: status, body: bytes)
        }
        var chunks: [Data] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: size, limitedBy: bytes.endIndex) ?? bytes.endIndex
            chunks.append(bytes[start..<end])
            start = end
        }
        return ResearchHTTPLineResponse(status: status, chunks: chunks)
    }
}

private func client(_ transport: any ResearchHTTPTransport,
                    streaming: Bool = true) -> ResearchChatClient {
    ResearchChatClient(serverURL: URL(string: "http://127.0.0.1:8080")!, model: "qwen36",
                       maxTokens: 512, enableThinking: nil, streaming: streaming,
                       transport: transport)
}

private func complete(_ client: ResearchChatClient) async throws -> ResearchAssistantTurn {
    try await client.complete(
        messages: [.object(["role": .string("user"), "content": .string("Hallo")])],
        tools: [])
}

/// The turn the client builds from a recording of an HTTP 200 stream.
private func turn(of name: String, chunkSize: Int? = nil) async throws -> ResearchAssistantTurn {
    try await complete(client(RecordingTransport(try Recording.data(name), chunkSize: chunkSize)))
}

/// The error the client throws for a reply, or nil when it returns a turn.
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

private let contextLengthExceeded = ResearchError.modelRequestFailed(
    status: 400, message: "prompt exceeds the configured context",
    code: "context_length_exceeded")

private let answerRecordings = [
    "tuff-answer", "tuff-answer-thinking", "tuff-answer-length", "tuff-tool-call",
    "tuff-answer-queued",
]

// MARK: tests

@Suite("Web research TUFF stream recordings")
struct ResearchStreamRecordingTests {
    // MARK: the files themselves

    @Test func theRecordingsAreAsTheServerWroteThem() throws {
        for name in answerRecordings + ["tuff-error-in-stream"] {
            let bytes = try Recording.data(name)
            // LF only, and a stream ends with `data: [DONE]` and a blank line.
            #expect(!bytes.contains(0x0D), "\(name) has a carriage return")
            let text = try Recording.text(name)
            #expect(text.hasPrefix("data: {"), "\(name)")
            #expect(text.hasSuffix("data: [DONE]\n\n"), "\(name)")
            #expect(try Recording.lines(name).contains(": ping"), "\(name) has no ping")
        }
        // The refusal before the stream is a plain JSON body, not events.
        let refusal = try Recording.text("tuff-error-before-stream")
        #expect(refusal.hasPrefix(#"{"error":"#))
        #expect(!refusal.contains("data:"))
    }

    // MARK: a normal answer

    @Test func anAnswerIsTheTextOfItsChunks() async throws {
        let expected = try Recording.contentPieces("tuff-answer").joined()
        let result = try await turn(of: "tuff-answer")
        #expect(!expected.isEmpty)
        #expect(result.content == expected)
        #expect(result.content?.hasPrefix("A heat pump works by using a refrigerant cycle") == true)
        #expect(result.content?.hasSuffix("heating in winter and cooling in summer.") == true)
        #expect(result.finishReason == "stop")
        #expect(result.toolCalls.isEmpty)
        #expect(result.reasoning == nil)
        #expect(result.model == Recording.model)
    }

    @Test func theUsageChunkWithoutChoicesGivesThePromptTokens() async throws {
        let usage = try Recording.chunks("tuff-answer").filter { chunk in
            (chunk["choices"] as? [Any])?.isEmpty == true
        }
        #expect(usage.count == 1)
        #expect(try await turn(of: "tuff-answer").promptTokens == 37)
        #expect(try await turn(of: "tuff-answer-thinking").promptTokens == 35)
        #expect(try await turn(of: "tuff-answer-length").promptTokens == 35)
        #expect(try await turn(of: "tuff-tool-call").promptTokens == 420)
        #expect(try await turn(of: "tuff-answer-queued").promptTokens == 37)
    }

    // MARK: thinking

    @Test func reasoningIsKeptApartFromTheAnswer() async throws {
        let reasoning = try Recording.reasoningPieces("tuff-answer-thinking").joined()
        let content = try Recording.contentPieces("tuff-answer-thinking").joined()
        let result = try await turn(of: "tuff-answer-thinking")
        #expect(!reasoning.isEmpty)
        #expect(!content.isEmpty)
        #expect(result.reasoning == reasoning)
        #expect(result.content == content)
        #expect(result.reasoning?.hasPrefix("Here's a thinking process:") == true)
        #expect(result.content?.hasPrefix("\n\nA heat pump works by circulating") == true)
        #expect(result.finishReason == "stop")
        // The reasoning chunks come before the first content chunk (the Mac
        // report: reasoning from line 3, content from line 817).
        let lines = try Recording.lines("tuff-answer-thinking")
        let firstReasoning = lines.firstIndex { $0.contains(#""reasoning_content""#) }
        let firstContent = lines.firstIndex { $0.contains(#""content":"#) && !$0.contains("reasoning_content") }
        #expect(firstReasoning != nil && firstContent != nil)
        if let firstReasoning, let firstContent { #expect(firstReasoning < firstContent) }
    }

    // MARK: finish reasons

    @Test func aReplyCutByTheTokenLimitEndsWithLength() async throws {
        // The 64-token limit ended it inside the reasoning: no text at all.
        let reasoning = try Recording.reasoningPieces("tuff-answer-length").joined()
        let result = try await turn(of: "tuff-answer-length")
        #expect(try Recording.contentPieces("tuff-answer-length").isEmpty)
        #expect(result.finishReason == "length")
        #expect(result.content == "")
        #expect(!reasoning.isEmpty)
        #expect(result.reasoning == reasoning)
        #expect(result.toolCalls.isEmpty)
    }

    @Test func aToolCallArrivesWholeWithItsArguments() async throws {
        let result = try await turn(of: "tuff-tool-call")
        #expect(result.finishReason == "tool_calls")
        #expect(result.content == nil)
        #expect(result.reasoning == nil)
        #expect(result.toolCalls.count == 1)
        let call = try #require(result.toolCalls.first)
        #expect(call.id == "call_748d39ac042b6d5a36d8ed8b")
        #expect(call.name == "web_search")
        #expect(call.arguments
            == #"{"query":"current federal subsidy for heat pumps in Germany 2024 2025"}"#)
        // The arguments are JSON text that parses.
        let parsed = try JSONSerialization.jsonObject(with: Data(call.arguments.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["query"] as? String == "current federal subsidy for heat pumps in Germany 2024 2025")
    }

    // MARK: [DONE] and `: ping`

    @Test func doneEndsTheStreamAndLaterLinesAreNotRead() throws {
        for name in answerRecordings {
            let lines = try Recording.lines(name)
            var assembler = ResearchStreamAssembler()
            var ended = false
            for line in lines {
                if try assembler.feed(line) { ended = true; break }
            }
            #expect(ended, "\(name)")
            #expect(assembler.isDone, "\(name)")
            let before = try assembler.finish()
            // A chunk after [DONE] changes nothing.
            try assembler.feed(#"data: {"choices":[{"index":0,"delta":{"content":"LATE"}}]}"#)
            #expect(try assembler.finish() == before, "\(name)")
            // `assemble` stops at [DONE] as well.
            let tail = lines + [#"data: {"choices":[{"index":0,"delta":{"content":"LATE"}}]}"#]
            #expect(try ResearchStreamAssembler.assemble(lines: tail) == before, "\(name)")
        }
    }

    @Test func pingCommentsAreIgnoredWhereverTheyAre() throws {
        for name in answerRecordings {
            let lines = try Recording.lines(name)
            let pings = lines.filter { $0 == ": ping" }.count
            #expect(pings >= 1, "\(name)")
            let without = lines.filter { $0 != ": ping" }
            #expect(without.count == lines.count - pings)
            #expect(try ResearchStreamAssembler.assemble(lines: lines)
                == ResearchStreamAssembler.assemble(lines: without), "\(name)")
        }
    }

    @Test func pingsBeforeTheFirstTextChunkOfAQueuedRequestAreIgnored() async throws {
        // The queued request got its role chunk, then six pings while it
        // waited, and only then the first chunk with text.
        let lines = try Recording.lines("tuff-answer-queued")
        let firstPing = try #require(lines.firstIndex(of: ": ping"))
        let firstText = try #require(lines.firstIndex { $0.contains(#""content":"#) })
        let before = lines[..<firstText].filter { $0 == ": ping" }.count
        #expect(firstPing < firstText)
        #expect(before == 6)
        let expected = try Recording.contentPieces("tuff-answer-queued").joined()
        let result = try await turn(of: "tuff-answer-queued")
        #expect(!expected.isEmpty)
        #expect(result.content == expected)
        #expect(result.content?.hasPrefix("A heat pump operates by using a refrigerant cycle") == true)
        #expect(result.finishReason == "stop")
        #expect(result.promptTokens == 37)
    }

    @Test func aPingDirectlyBeforeTheFirstLineIsIgnored() throws {
        let lines = [": ping", ""] + (try Recording.lines("tuff-answer"))
        #expect(try ResearchStreamAssembler.assemble(lines: lines)
            == ResearchStreamAssembler.assemble(lines: Recording.lines("tuff-answer")))
    }

    // MARK: cut into pieces anywhere

    @Test func theSameTurnComesWhateverThePieceSize() async throws {
        for name in answerRecordings {
            let whole = try await turn(of: name)
            for size in [1, 7, 64, 1000] {
                #expect(try await turn(of: name, chunkSize: size) == whole, "\(name) size \(size)")
            }
        }
    }

    @Test func theAssemblerAndTheClientAgree() async throws {
        for name in answerRecordings {
            let direct = try ResearchStreamAssembler.assemble(lines: Recording.lines(name))
            #expect(try await turn(of: name) == direct, "\(name)")
        }
    }

    // MARK: errors

    @Test func anErrorInsideTheStreamIsTheContextLengthError() async throws {
        // HTTP 200, a first chunk, five pings, then `data: {"error":…}` and
        // [DONE]: the status comes from the code, as without streaming.
        #expect(await failure(client(RecordingTransport(try Recording.data("tuff-error-in-stream"))))
            == contextLengthExceeded)
        #expect(await failure(client(RecordingTransport(
            try Recording.data("tuff-error-in-stream"), chunkSize: 5))) == contextLengthExceeded)
    }

    @Test func anErrorInTheStreamEndsTheAssemblyAtThatLine() throws {
        let lines = try Recording.lines("tuff-error-in-stream")
        #expect(lines.filter { $0 == ": ping" }.count == 5)
        var assembler = ResearchStreamAssembler()
        var thrown: ResearchError?
        var fed = 0
        for line in lines {
            do {
                if try assembler.feed(line) { break }
            } catch let error as ResearchError {
                thrown = error
                break
            }
            fed += 1
        }
        #expect(thrown == contextLengthExceeded)
        // Nothing but the role chunk and the pings came before it.
        #expect(!assembler.isDone)
        #expect(fed == lines.firstIndex { $0.contains(#""error""#) })
    }

    @Test func aRefusalBeforeTheStreamIsTheSameErrorAsInsideIt() async throws {
        let body = try Recording.data("tuff-error-before-stream")
        // HTTP 400 with a JSON body: through the streaming path, through the
        // plain reply path (`send`), and without streaming.
        let streaming = await failure(client(RecordingTransport(body, status: 400)))
        #expect(streaming == contextLengthExceeded)
        #expect(await failure(client(RecordingTransport(body, status: 400, chunkSize: 3)))
            == contextLengthExceeded)
        #expect(await failure(client(RecordingTransport(body, status: 400), streaming: false))
            == contextLengthExceeded)
        // And it is the error of the in-stream refusal: the agent cannot tell which.
        let inStream = await failure(client(RecordingTransport(
            try Recording.data("tuff-error-in-stream"))))
        #expect(streaming == inStream)
    }
}
