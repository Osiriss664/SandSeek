import Foundation
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
                     allowTools: Bool,
                     thinking: Bool? = nil) -> ResearchJSON {
        var body: [String: ResearchJSON] = [
            "model": .string(model),
            "messages": .array(messages),
            "max_tokens": .integer(maxTokens),
            "stream": .bool(false),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            body["tool_choice"] = .string(allowTools ? "auto" : "none")
        }
        if let thinking = thinking ?? enableThinking {
            body["enable_thinking"] = .bool(thinking)
        }
        return .object(body)
    }

    public func complete(messages: [ResearchJSON],
                         tools: [ResearchJSON],
                         allowTools: Bool = true,
                         thinking: Bool? = nil) async throws -> ResearchAssistantTurn {
        let body = try requestBody(messages: messages, tools: tools, allowTools: allowTools,
                                   thinking: thinking).encoded()
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(method: "POST", url: endpoint, body: body)
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
                                     promptTokens: reply?["usage"]?["prompt_tokens"]?.intValue)
    }

    /// The model's context window in tokens, as TUFF lists it in
    /// `/v1/models`, or nil when the server does not say. A name the list
    /// does not hold, such as `default`, gets the smallest listed window.
    public func contextTokens() async -> Int? {
        guard let response = try? await transport.send(
                method: "GET", url: endpoint.deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("models"),
                body: nil),
              response.status == 200,
              let models = (try? ResearchJSON.decode(response.body))?["data"]?.arrayValue
        else { return nil }
        let windows = models.compactMap { entry -> (id: String, tokens: Int)? in
            guard let id = entry["id"]?.stringValue,
                  let tokens = entry["context_length"]?.intValue, tokens > 0 else { return nil }
            return (id, tokens)
        }
        // `tuff research --model qwen36` names the model by its selector.
        let names = [model] + TUFFModelCatalog.all.filter { $0.selector == model }.map(\.apiModelID)
        return windows.first { names.contains($0.id) }?.tokens ?? windows.map(\.tokens).min()
    }
}
