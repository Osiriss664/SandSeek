import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ResearchToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    /// The arguments exactly as the model wrote them, a JSON object string.
    public let arguments: String
}

public struct ResearchAssistantTurn: Equatable, Sendable {
    public let content: String?
    public let toolCalls: [ResearchToolCall]
    /// The model's reasoning, when the server returns `reasoning_content`.
    public var reasoning: String? = nil
    /// Why the turn ended: `stop`, `tool_calls`, or `length` when it reached
    /// the token limit.
    public var finishReason: String? = nil
    /// Tokens the server counted in the prompt, when it reports usage.
    public var promptTokens: Int? = nil
    /// The model that answered, as the server names it.
    public var model: String? = nil
}

/// How a run decides whether to send `preserve_thinking`. `auto` is the rule
/// in `ResearchChatClient.preserveThinkingForRun`; `on` and `off` force it,
/// for measuring the prompt cache on a Mac (`SANDSEEK_PRESERVE_THINKING`).
public enum ResearchPreserveThinking: String, Equatable, Sendable {
    case auto, on, off
}

/// Whether a request lets the model call tools. `.discouraged` is for an
/// "answer now" request: the tools stay in the prompt with `tool_choice=auto`
/// so the rendered tool block, which the server's prompt cache needs to
/// match, stays the same, and the request text asks for an answer. Only
/// `.off` sends `tool_choice=none`, which the server renders without the
/// tools. A request that also changes the reasoning mode still misses.
public enum ResearchToolUse: Sendable {
    case allowed, discouraged, off
}

/// Talks to TUFF's OpenAI-compatible Chat Completions endpoint. It sends only
/// fields TUFF accepts: the server refuses unknown keys, and it refuses
/// `tool_choice=required` and `parallel_tool_calls=false`, so neither is used.
///
/// With `streaming` the reply is read as a stream (server-sent events) and
/// put together by `ResearchStreamAssembler`; without it the request is the
/// plain one-reply request the client has always sent. Streaming is what lets
/// TUFF notice that the client hung up (see `URLSessionResearchTransport`).
public struct ResearchChatClient: Sendable {
    public let endpoint: URL
    public let model: String
    public let maxTokens: Int
    public let enableThinking: Bool?
    public let streaming: Bool
    /// The `Authorization` header value for every request, such as
    /// `Bearer <key>` for a llama.cpp server started with `--api-key`. Sent
    /// as that header only: never in a body or URL, and not printed.
    private let authorization: String?
    private let transport: any ResearchHTTPTransport

    public init(serverURL: URL,
                model: String,
                maxTokens: Int,
                enableThinking: Bool?,
                streaming: Bool = false,
                authorization: String? = nil,
                transport: any ResearchHTTPTransport) {
        var base = serverURL.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        endpoint = URL(string: base + "/v1/chat/completions")!
        self.model = model
        self.maxTokens = maxTokens
        self.enableThinking = enableThinking
        self.streaming = streaming
        self.authorization = authorization
        self.transport = transport
    }

    func requestBody(messages: [ResearchJSON],
                     tools: [ResearchJSON],
                     toolUse: ResearchToolUse,
                     thinking: Bool? = nil,
                     preserveThinking: Bool = false) -> ResearchJSON {
        var body: [String: ResearchJSON] = [
            "model": .string(model),
            "messages": .array(messages),
            "max_tokens": .integer(maxTokens),
            "stream": .bool(streaming),
        ]
        if streaming {
            // TUFF 8.3.1 accepts `stream_options`; with `include_usage` it
            // ends the stream with a chunk that counts the prompt's tokens.
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = .string(toolUse == .off ? "none" : "auto")
        }
        if let thinking = thinking ?? enableThinking {
            body["enable_thinking"] = .bool(thinking)
        }
        // Decided once for the run (`preserveThinkingForRun`) and the same on
        // every request: the server's prompt cache only matches a request
        // whose flag equals the cached one. See `ResearchPreserveThinking`.
        if preserveThinking {
            body["preserve_thinking"] = .bool(true)
        }
        return .object(body)
    }

    /// Whether the run sends `preserve_thinking`. The value is fixed for the
    /// whole run, because the server's prompt cache only matches a request
    /// whose flag equals the cached request's. In `auto` it is sent when
    /// reasoning is on, or when the model family keeps reasoning in its chat
    /// history (Qwen, MiniMax, GPT-OSS): without the flag, Qwen's template
    /// drops the empty think blocks of earlier turns once a user message
    /// comes last, and the cached prefix is missed. Only Gemma with
    /// reasoning off leaves it out, which lets the server continue a
    /// plain-text turn from its cache with a text bridge. `modelID` is the
    /// model's id as the server lists it, or nil when it is not known; an
    /// unknown model gets the flag.
    public static func preserveThinkingForRun(mode: ResearchPreserveThinking,
                                              enableThinking: Bool?,
                                              modelID: String?) -> Bool {
        switch mode {
        case .on: return true
        case .off: return false
        case .auto: return enableThinking == true || keepsReasoning(modelID: modelID)
        }
    }

    /// False only for the Gemma family; true for every other model and for an
    /// unknown one.
    static func keepsReasoning(modelID: String?) -> Bool {
        guard let modelID, !modelID.isEmpty else { return true }
        let lowered = modelID.lowercased()
        if let known = ResearchModelTable.model(matching: modelID) {
            return known.family != .gemma4
        }
        if ["qwen", "minimax", "gpt-oss"].contains(where: { lowered.contains($0) }) { return true }
        return !lowered.contains("gemma")
    }

    public func complete(messages: [ResearchJSON],
                         tools: [ResearchJSON],
                         toolUse: ResearchToolUse = .allowed,
                         thinking: Bool? = nil,
                         preserveThinking: Bool = false,
                         timeout: TimeInterval? = nil) async throws -> ResearchAssistantTurn {
        let body = try requestBody(messages: messages, tools: tools, toolUse: toolUse,
                                   thinking: thinking,
                                   preserveThinking: preserveThinking).encoded()
        if streaming { return try await completeStreaming(body: body, timeout: timeout) }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "POST", url: endpoint, body: body, timeout: timeout,
                authorization: authorization)
        } catch let error as URLError where error.code == .timedOut {
            throw ResearchError.modelTimedOut
        } catch {
            throw ResearchError.modelUnavailable(error.localizedDescription)
        }
        let reply = try? ResearchJSON.decode(response.body)
        guard (200..<300).contains(response.status) else {
            throw Self.requestFailure(status: response.status, body: response.body, reply: reply)
        }
        let choice = reply?["choices"]?.arrayValue?.first
        guard let message = choice?["message"] else {
            throw ResearchError.malformedModelReply("no choices[0].message")
        }
        let calls = try (message["tool_calls"]?.arrayValue ?? []).map { call in
            guard let id = call["id"]?.stringValue,
                  let name = call["function"]?["name"]?.stringValue,
                  let arguments = call["function"]?["arguments"]?.stringValue else {
                throw ResearchError.malformedModelReply("tool call without id, name or arguments")
            }
            return ResearchToolCall(id: id, name: name, arguments: arguments)
        }
        return ResearchAssistantTurn(content: message["content"]?.stringValue, toolCalls: calls,
                                     reasoning: message["reasoning_content"]?.stringValue,
                                     finishReason: choice?["finish_reason"]?.stringValue,
                                     promptTokens: reply?["usage"]?["prompt_tokens"]?.intValue,
                                     model: reply?["model"]?.stringValue)
    }

    /// The error for a reply with a status other than 2xx, from its body.
    private static func requestFailure(status: Int, body: Data,
                                       reply: ResearchJSON?) -> ResearchError {
        let detail = reply?["error"]
        return .modelRequestFailed(
            status: status,
            message: detail?["message"]?.stringValue
                ?? String(decoding: body.prefix(500), as: UTF8.self),
            code: detail?["code"]?.stringValue)
    }

    /// The same turn through a stream. Errors are the ones `complete` always
    /// threw: `modelTimedOut` for a time limit, `modelUnavailable` for a
    /// connection that failed, `modelRequestFailed` for a refusal, which
    /// TUFF answers with a status before the stream or inside it; the agent
    /// cannot tell which. A cancelled task throws `CancellationError`, also when
    /// the Stop came before the headers.
    private func completeStreaming(body: Data,
                                   timeout: TimeInterval?) async throws -> ResearchAssistantTurn {
        let response: ResearchHTTPLineResponse
        do {
            response = try await transport.sendStreaming(
                method: "POST", url: endpoint, body: body, timeout: timeout,
                authorization: authorization)
        } catch let error as URLError where error.code == .timedOut {
            throw ResearchError.modelTimedOut
        } catch {
            // A Stop before the headers arrive ends `bytes(for:)` with
            // `URLError(.cancelled)`; it is a stop all the same.
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw ResearchError.modelUnavailable(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else {
            // Refused before the stream began: the rest is an ordinary error
            // body, handled as it is without streaming.
            var lines: [String] = []
            do {
                for try await line in response.lines { lines.append(line) }
            } catch let error as URLError where error.code == .timedOut {
                throw ResearchError.modelTimedOut
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw ResearchError.modelUnavailable(error.localizedDescription)
            }
            // The lines were cut at CR and LF only (`SSELineBuffer`), so a
            // JSON string with U+2028 in it is intact; they are joined with
            // LF, which is white space between JSON tokens.
            let text = lines.joined(separator: "\n")
            let data = Data(text.utf8)
            throw Self.requestFailure(
                status: response.status, body: data, reply: try? ResearchJSON.decode(data))
        }
        do {
            return try await ResearchStreamAssembler.assemble(response.lines)
        } catch let error as ResearchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ResearchError.modelTimedOut
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ResearchError.modelUnavailable(error.localizedDescription)
        }
    }

    /// The models TUFF lists in `/v1/models`, with each one's context window
    /// in tokens when it says. Empty when the server does not answer.
    public func listedModels() async -> [(id: String, contextTokens: Int?)] {
        guard let response = try? await transport.send(
                method: "GET", url: endpoint.deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("models"),
                body: nil, timeout: nil, authorization: authorization),
              response.status == 200,
              let models = (try? ResearchJSON.decode(response.body))?["data"]?.arrayValue
        else { return [] }
        return models.compactMap { entry -> (id: String, contextTokens: Int?)? in
            guard let id = entry["id"]?.stringValue else { return nil }
            let tokens = entry["context_length"]?.intValue
            return (id: id, contextTokens: tokens.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// The context window of each model TUFF lists in `/v1/models`, in
    /// tokens. Empty when the server does not say.
    public func contextWindows() async -> [String: Int] {
        Self.windows(from: await listedModels())
    }

    static func windows(from models: [(id: String, contextTokens: Int?)]) -> [String: Int] {
        let windows = models.compactMap { entry -> (String, Int)? in
            entry.contextTokens.map { (entry.id, $0) }
        }
        return Dictionary(windows, uniquingKeysWith: min)
    }

    /// The window for `model`. `sandseek --model qwen36` names it by its
    /// selector. A name the list does not hold, such as `default`, gets the
    /// smallest window until a reply says which model answered.
    public static func window(for model: String, in windows: [String: Int]) -> Int? {
        let names = [model] + ResearchModelTable.apiModelIDs(forSelector: model)
        return names.lazy.compactMap { windows[$0] }.first ?? windows.values.min()
    }

    /// The model's context window in tokens, or nil when the server does not say.
    public func contextTokens() async -> Int? {
        Self.window(for: model, in: await contextWindows())
    }
}
