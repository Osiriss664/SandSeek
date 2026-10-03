import Foundation

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
                     allowTools: Bool) -> ResearchJSON {
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
        if let enableThinking {
            body["enable_thinking"] = .bool(enableThinking)
        }
        return .object(body)
    }

    public func complete(messages: [ResearchJSON],
                         tools: [ResearchJSON],
                         allowTools: Bool = true) async throws -> ResearchAssistantTurn {
        let body = try requestBody(messages: messages, tools: tools, allowTools: allowTools)
            .encoded()
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
        guard let message = reply?["choices"]?.arrayValue?.first?["message"] else {
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
                                     reasoning: message["reasoning_content"]?.stringValue)
    }
}
