import Foundation

/// Builds one assistant turn from the lines of a chat completion stream
/// (server-sent events), as TUFF 8.3.1 writes them. It is pure: it reads
/// lines and nothing else, so it is tested with fixtures and no server.
///
/// The turn is the one the non-streaming path builds from the same full
/// message, character for character. Text and reasoning are appended exactly
/// as they arrive, with no trimming: the server's prompt cache compares the
/// earlier assistant turns of a conversation byte for byte, and a turn that
/// differs from what the server itself rendered makes every later step start
/// cold.
///
/// What it reads:
/// - empty lines and lines starting with ":" (TUFF's `: ping` heartbeat) are
///   skipped, and so are SSE fields other than `data:`;
/// - `data: [DONE]` ends the stream, and later lines are ignored;
/// - in `choices[0].delta`: `content`, `reasoning_content`, and `tool_calls`
///   pieces, which are joined by their `index` (`id`, `type` and `name` come
///   in an index's first piece, `function.arguments` in pieces that are
///   concatenated in order); in `choices[0]`: `finish_reason`;
/// - `model` of any chunk;
/// - `usage.prompt_tokens`, which TUFF sends in a chunk with `choices: []`
///   when the request set `stream_options.include_usage`. A stream without it
///   is fine; the turn then has no `promptTokens`;
/// - an `error` object, which TUFF sends in the stream (with HTTP status 200)
///   when a request fails after the stream has started, even after text.
///   It becomes `ResearchError.modelRequestFailed`, the error the agent's
///   rules already act on, and the partial turn is discarded.
public struct ResearchStreamAssembler: Sendable {
    private struct PartialCall: Sendable {
        var id: String?
        var name: String?
        var arguments: String?
    }

    private var content: String?
    private var reasoning: String?
    private var calls: [Int: PartialCall] = [:]
    private var lastCallIndex: Int?
    private var finishReason: String?
    private var promptTokens: Int?
    private var model: String?
    private var sawChoice = false
    private var sawDataLine = false
    /// The first non-empty line that is no part of server-sent events, such
    /// as the `{` that opens a plain JSON reply.
    private var firstForeignLine: String?

    /// True once `data: [DONE]` has been read.
    public private(set) var isDone = false

    public init() {}

    /// Reads one line. Returns true when it was `data: [DONE]`, after which
    /// the stream is over and further lines change nothing. Throws the
    /// model's error when the line carries one, or `malformedModelReply` for
    /// a `data:` line that is not JSON.
    @discardableResult
    public mutating func feed(_ line: String) throws -> Bool {
        if isDone { return true }
        // A line from a source that kept its carriage return.
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        // Skipped: empty lines (the end of an event), comments (`: ping`),
        // and other SSE fields (`event:`, `id:`, `retry:`).
        guard text.hasPrefix("data:") else {
            if firstForeignLine == nil, !Self.isServerSentEventsLine(text) {
                firstForeignLine = String(text.prefix(100))
            }
            return false
        }
        sawDataLine = true
        var payload = text.dropFirst("data:".count)
        if payload.first == " " { payload = payload.dropFirst() }
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed == "[DONE]" {
            isDone = true
            return true
        }
        guard let chunk = try? ResearchJSON.decode(Data(payload.utf8)) else {
            throw ResearchError.malformedModelReply(
                "unreadable stream chunk: " + String(payload.prefix(200)))
        }
        if let error = chunk["error"], error != .null {
            throw Self.failure(error, payload: payload)
        }
        if let model = chunk["model"]?.stringValue { self.model = model }
        if let tokens = chunk["usage"]?["prompt_tokens"]?.intValue { promptTokens = tokens }
        guard let choice = chunk["choices"]?.arrayValue?.first else { return false }
        sawChoice = true
        if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }
        if let delta = choice["delta"] { apply(delta) }
        return false
    }

    /// The turn, once the stream has ended. Throws `malformedModelReply` for
    /// a stream that ended before the model finished: no `[DONE]` and no
    /// `finish_reason` (the connection dropped or the server went away), or
    /// no choice at all. A tool call without id, name or arguments throws as
    /// the non-streaming path does.
    public func finish() throws -> ResearchAssistantTurn {
        guard sawChoice else {
            if !sawDataLine, let foreign = firstForeignLine {
                throw ResearchError.malformedModelReply(
                    "the server did not stream its reply: it answered with plain text and "
                        + "not server-sent events (it starts with: \(foreign)). "
                        + "Try --stream off.")
            }
            throw ResearchError.malformedModelReply("the stream held no choices[0]")
        }
        guard isDone || finishReason != nil else {
            throw ResearchError.malformedModelReply(
                "the stream ended before the model finished (no finish_reason, no [DONE])")
        }
        let toolCalls = try calls.keys.sorted().map { index -> ResearchToolCall in
            guard let call = calls[index], let id = call.id, let name = call.name,
                  let arguments = call.arguments else {
                throw ResearchError.malformedModelReply(
                    "tool call without id, name or arguments")
            }
            return ResearchToolCall(id: id, name: name, arguments: arguments)
        }
        // TUFF's non-streamed reply has `content: ""` unless the reply holds
        // tool calls and no text, then `null`; a stream sends no content
        // delta for empty text, so the same rule is applied here.
        return ResearchAssistantTurn(content: content ?? (toolCalls.isEmpty ? "" : nil),
                                     toolCalls: toolCalls,
                                     reasoning: reasoning, finishReason: finishReason,
                                     promptTokens: promptTokens, model: model)
    }

    /// Reads a whole stream and returns its turn. The stream is read only up
    /// to `[DONE]`; leaving the loop there lets the transport close the
    /// connection. A cancelled task throws `CancellationError` and not
    /// `malformedModelReply`: a cancelled stream also just ends.
    public static func assemble<Lines: AsyncSequence>(
        _ lines: Lines
    ) async throws -> ResearchAssistantTurn where Lines.Element == String {
        var assembler = ResearchStreamAssembler()
        for try await line in lines {
            if try assembler.feed(line) { break }
        }
        try Task.checkCancellation()
        return try assembler.finish()
    }

    /// The same for lines that are all there already.
    public static func assemble(lines: [String]) throws -> ResearchAssistantTurn {
        var assembler = ResearchStreamAssembler()
        for line in lines {
            if try assembler.feed(line) { break }
        }
        return try assembler.finish()
    }

    private mutating func apply(_ delta: ResearchJSON) {
        if let text = delta["content"]?.stringValue {
            if content == nil { content = text } else { content?.append(text) }
        }
        if let text = delta["reasoning_content"]?.stringValue {
            if reasoning == nil { reasoning = text } else { reasoning?.append(text) }
        }
        for piece in delta["tool_calls"]?.arrayValue ?? [] {
            let id = Self.nonEmpty(piece["id"]?.stringValue)
            let name = Self.nonEmpty(piece["function"]?["name"]?.stringValue)
            // `index` tells the calls apart. A piece without one belongs to
            // the call before it, or starts a new call when it has an id.
            let index: Int
            if let given = piece["index"]?.intValue {
                index = given
            } else if id != nil {
                index = (calls.keys.max() ?? -1) + 1
            } else {
                index = lastCallIndex ?? 0
            }
            var call = calls[index] ?? PartialCall()
            if call.id == nil { call.id = id }
            if call.name == nil { call.name = name }
            if let arguments = piece["function"]?["arguments"]?.stringValue {
                if call.arguments == nil {
                    call.arguments = arguments
                } else {
                    call.arguments?.append(arguments)
                }
            }
            calls[index] = call
            lastCallIndex = index
        }
    }

    /// Whether a line that is not `data:` belongs to server-sent events: an
    /// empty line, a comment, or one of the other fields.
    private static func isServerSentEventsLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || text.hasPrefix(":") { return true }
        return ["data", "event", "id", "retry"].contains { field in
            text == field || text.hasPrefix(field + ":")
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The HTTP status TUFF 8.3.1 gives each error code it can write
    /// (`ServerRequestError.httpStatus` in HTTPServer.swift at 58ae663,
    /// `handleAsyncError` for the internal error). A stream carries no
    /// status, so the same statuses are derived from the code, and the agent
    /// reacts as it does without streaming: a status of 500 or more is
    /// retried (`model_memory_busy` is 503), and `context_length_exceeded`
    /// (400) shortens the conversation. In Abschnitt 2b this table belongs
    /// to the TUFF connector, and llama.cpp gets its own.
    static let tuffStatus: [String: Int] = [
        "model_not_found": 404,
        "queue_full": 429,
        "model_memory_busy": 503,
        "request_too_large": 413,
        "image_too_large": 413,
        "too_many_images": 413,
        "context_length_exceeded": 400,
        "internal_error": 500,
        "server_error": 500,
    ]

    /// An error in the stream, as the agent already knows it. The stream
    /// carries no status, so it is derived: from `tuffStatus` by the code;
    /// else 500 for a `server_error` (read as a code or as a type); else 400.
    /// The code is `error.code` when it is a string (TUFF), else `error.type`
    /// (llama.cpp has a number in `code`).
    static func failure(_ error: ResearchJSON, payload: Substring) -> ResearchError {
        let type = error["type"]?.stringValue
        let code = error["code"]?.stringValue
        let serverError = code == "server_error" || type == "server_error"
        let status = code.flatMap { tuffStatus[$0] } ?? (serverError ? 500 : 400)
        return .modelRequestFailed(
            status: status,
            message: error["message"]?.stringValue ?? String(payload.prefix(500)),
            code: code ?? type)
    }
}
