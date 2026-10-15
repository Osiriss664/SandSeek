import Foundation

/// Builds one assistant turn from the lines of Ollama's `POST /api/chat`
/// stream (newline-delimited JSON, one object per line, no `data:` prefix),
/// or from the single object of a reply without streaming. It is pure: it
/// reads lines and nothing else, so it is tested with fixtures and no server.
///
/// As for `ResearchStreamAssembler`, text and reasoning are appended exactly
/// as they arrive, with no trimming.
///
/// What it reads, in each object:
/// - `message.content` and `message.thinking` pieces, which are joined in
///   order;
/// - `message.tool_calls`: whole calls (Ollama never splits one), which may
///   arrive in any line. A call's `function.arguments` is a JSON object and
///   is written back as the JSON object string the loop works with. A call
///   has the server's `id`, or `call_<n>` when the server sent none;
/// - `model`, and `prompt_eval_count` as the tokens in the prompt;
/// - `done: true` with `done_reason`, which ends the stream. Later lines are
///   ignored. `stop` and `length` are kept; a turn that holds tool calls
///   reports `tool_calls`, as the OpenAI-style reply does, so the loop acts
///   the same;
/// - `error`, a string, which Ollama writes as a line of the stream (with HTTP
///   status 200) when a request fails after the stream has started. It
///   becomes `ResearchError.modelRequestFailed`, and the partial turn is
///   discarded.
public struct ResearchOllamaStreamAssembler: Sendable {
    private var content: String?
    private var reasoning: String?
    private var calls: [ResearchToolCall] = []
    private var doneReason: String?
    private var promptTokens: Int?
    private var model: String?
    private var sawMessage = false
    private var nextCallNumber: Int

    /// True once an object with `done: true` has been read.
    public private(set) var isDone = false

    /// `firstCallNumber` is the number of the first call that has to be given
    /// an id of the form `call_<n>`.
    public init(firstCallNumber: Int = 1) {
        nextCallNumber = firstCallNumber
    }

    /// Reads one line. Returns true when it ended the stream (`done: true`),
    /// after which further lines change nothing. An empty line is skipped.
    /// Throws the model's error when the line carries one, or
    /// `malformedModelReply` for a line that is not a JSON object.
    @discardableResult
    public mutating func feed(_ line: String) throws -> Bool {
        if isDone { return true }
        // A line from a source that kept its carriage return.
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        guard let chunk = try? ResearchJSON.decode(Data(text.utf8)),
              chunk.objectValue != nil else {
            throw ResearchError.malformedModelReply(
                "unreadable stream line: " + String(text.prefix(200)))
        }
        return try feed(json: chunk)
    }

    /// Reads one decoded object: a line of the stream, or the whole reply
    /// of a request without streaming.
    @discardableResult
    public mutating func feed(json chunk: ResearchJSON) throws -> Bool {
        if isDone { return true }
        if let error = chunk["error"], error != .null {
            throw ResearchOllama.failure(error, status: chunk["status"]?.intValue)
        }
        if let model = chunk["model"]?.stringValue { self.model = model }
        if let tokens = chunk["prompt_eval_count"]?.intValue { promptTokens = tokens }
        if let message = chunk["message"], message.objectValue != nil {
            sawMessage = true
            try apply(message)
        }
        if chunk["done"] == ResearchJSON.bool(true) {
            doneReason = chunk["done_reason"]?.stringValue
            isDone = true
        }
        return isDone
    }

    /// The turn, once the stream has ended. Throws `malformedModelReply` for
    /// a stream that ended before the model finished (no `done: true`: the
    /// connection dropped or the server went away), or that held no message
    /// at all. `requireDone: false` is for the reply to a request without
    /// streaming, which is one object.
    public func finish(requireDone: Bool = true) throws -> ResearchAssistantTurn {
        guard sawMessage || isDone else {
            throw ResearchError.malformedModelReply("the reply held no message")
        }
        if requireDone, !isDone {
            throw ResearchError.malformedModelReply(
                "the stream ended before the model finished (no done: true)")
        }
        let text = content ?? ""
        // The same rule as the OpenAI-style reply: no `content` when the turn
        // holds tool calls and no text.
        let turnContent: String? = text.isEmpty && !calls.isEmpty ? nil : text
        let reason = calls.isEmpty ? doneReason : "tool_calls"
        return ResearchAssistantTurn(content: turnContent, toolCalls: calls,
                                     reasoning: reasoning, finishReason: reason,
                                     promptTokens: promptTokens, model: model)
    }

    /// Reads a whole stream and returns its turn. The stream is read only up
    /// to `done: true`; leaving the loop there lets the transport close the
    /// connection. A cancelled task throws `CancellationError` and not
    /// `malformedModelReply`: a cancelled stream also just ends.
    /// `firstCallNumber` is the number for the first call without an id.
    public static func assemble<Lines: AsyncSequence>(
        _ lines: Lines, firstCallNumber: Int = 1
    ) async throws -> ResearchAssistantTurn where Lines.Element == String {
        var assembler = ResearchOllamaStreamAssembler(firstCallNumber: firstCallNumber)
        for try await line in lines {
            if try assembler.feed(line) { break }
        }
        try Task.checkCancellation()
        return try assembler.finish()
    }

    /// The same for lines that are all there already.
    public static func assemble(lines: [String],
                                firstCallNumber: Int = 1) throws -> ResearchAssistantTurn {
        var assembler = ResearchOllamaStreamAssembler(firstCallNumber: firstCallNumber)
        for line in lines {
            if try assembler.feed(line) { break }
        }
        return try assembler.finish()
    }

    private mutating func apply(_ message: ResearchJSON) throws {
        if let text = message["content"]?.stringValue {
            if content == nil { content = text } else { content?.append(text) }
        }
        if let text = message["thinking"]?.stringValue, !text.isEmpty {
            if reasoning == nil { reasoning = text } else { reasoning?.append(text) }
        }
        for call in message["tool_calls"]?.arrayValue ?? [] {
            guard let name = call["function"]?["name"]?.stringValue, !name.isEmpty else {
                throw ResearchError.malformedModelReply("tool call without a name")
            }
            let id: String
            if let given = call["id"]?.stringValue, !given.isEmpty {
                id = given
            } else {
                id = "call_\(nextCallNumber)"
                nextCallNumber += 1
            }
            calls.append(ResearchToolCall(
                id: id, name: name,
                arguments: Self.argumentsText(call["function"]?["arguments"])))
        }
    }

    /// The arguments as the JSON object string the loop works with. Ollama
    /// sends an object; a string is taken as it is, and anything else is the
    /// empty object (the loop then answers the call with a tool error).
    private static func argumentsText(_ arguments: ResearchJSON?) -> String {
        if let arguments {
            switch arguments {
            case .object:
                if let data = try? arguments.encoded() {
                    return String(decoding: data, as: UTF8.self)
                }
            case .string(let text):
                return text
            default:
                break
            }
        }
        return "{}"
    }
}
