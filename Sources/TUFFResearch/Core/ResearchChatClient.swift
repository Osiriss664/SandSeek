import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TUFFModelCatalog

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
public struct ResearchChatClient: Sendable {
    public let endpoint: URL
    public let model: String
    public let maxTokens: Int
    public let enableThinking: Bool?
    private let transport: any ResearchHTTPTransport

    public init(serverURL: URL,
                model: String,
                maxTokens: Int,
                enableThinking: Bool?,
                transport: any ResearchHTTPTransport) {
        var base = serverURL.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        endpoint = URL(string: base + "/v1/chat/completions")!
        self.model = model
        self.maxTokens = maxTokens
        self.enableThinking = enableThinking
        self.transport = transport
    }

    func requestBody(messages: [ResearchJSON],
                     tools: [ResearchJSON],
                     toolUse: ResearchToolUse,
                     thinking: Bool? = nil) -> ResearchJSON {
        var body: [String: ResearchJSON] = [
            "model": .string(model),
            "messages": .array(messages),
            "max_tokens": .integer(maxTokens),
            "stream": .bool(false),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = .string(toolUse == .off ? "none" : "auto")
        }
        if let thinking = thinking ?? enableThinking {
            body["enable_thinking"] = .bool(thinking)
        }
        // Sent only when reasoning has to be replayed: the request thinks, so
        // its reply carries `reasoning_content` that the next request sends
        // back, or the history already holds some. The server then renders
        // every earlier turn's reasoning, so the prompt is the tokens it
        // generated and its cache matches (ChatML only; other families drop
        // it). The flag is part of the cache's identity, so a run that
        // thinks sends it on every request, the first included. A request
        // with reasoning off and none in the history leaves it out: the
        // server then continues a plain-text turn from its cache with a text
        // bridge, which it does not do once the flag is set.
        let thinks = (thinking ?? enableThinking) == true
        if thinks || Self.replaysReasoning(messages) {
            body["preserve_thinking"] = .bool(true)
        }
        return .object(body)
    }

    /// Whether an assistant message in the history carries reasoning.
    static func replaysReasoning(_ messages: [ResearchJSON]) -> Bool {
        messages.contains { message in
            message["role"]?.stringValue == "assistant"
                && message["reasoning_content"]?.stringValue?.isEmpty == false
        }
    }

    public func complete(messages: [ResearchJSON],
                         tools: [ResearchJSON],
                         toolUse: ResearchToolUse = .allowed,
                         thinking: Bool? = nil,
                         timeout: TimeInterval? = nil) async throws -> ResearchAssistantTurn {
        let body = try requestBody(messages: messages, tools: tools, toolUse: toolUse,
                                   thinking: thinking).encoded()
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "POST", url: endpoint, body: body, timeout: timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw ResearchError.modelTimedOut
        } catch {
            throw ResearchError.modelUnavailable(error.localizedDescription)
        }
        let reply = try? ResearchJSON.decode(response.body)
        guard (200..<300).contains(response.status) else {
            let detail = reply?["error"]
            throw ResearchError.modelRequestFailed(
                status: response.status,
                message: detail?["message"]?.stringValue
                    ?? String(decoding: response.body.prefix(500), as: UTF8.self),
                code: detail?["code"]?.stringValue)
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

    /// The context window of each model TUFF lists in `/v1/models`, in
    /// tokens. Empty when the server does not say.
    public func contextWindows() async -> [String: Int] {
        guard let response = try? await transport.send(
                method: "GET", url: endpoint.deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("models"),
                body: nil),
              response.status == 200,
              let models = (try? ResearchJSON.decode(response.body))?["data"]?.arrayValue
        else { return [:] }
        let windows = models.compactMap { entry -> (String, Int)? in
            guard let id = entry["id"]?.stringValue,
                  let tokens = entry["context_length"]?.intValue, tokens > 0 else { return nil }
            return (id, tokens)
        }
        return Dictionary(windows, uniquingKeysWith: min)
    }

    /// The window for `model`. `tuff research --model qwen36` names it by its
    /// selector. A name the list does not hold, such as `default`, gets the
    /// smallest window until a reply says which model answered.
    public static func window(for model: String, in windows: [String: Int]) -> Int? {
        let names = [model] + TUFFModelCatalog.all.filter { $0.selector == model }.map(\.apiModelID)
        return names.lazy.compactMap { windows[$0] }.first ?? windows.values.min()
    }

    /// The model's context window in tokens, or nil when the server does not say.
    public func contextTokens() async -> Int? {
        Self.window(for: model, in: await contextWindows())
    }
}
