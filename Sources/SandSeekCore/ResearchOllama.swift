import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What SandSeek knows about Ollama's native API: how it names models, what
/// `/api/show` says about one, which context window a run asks for, and how
/// the loop's OpenAI-style messages become the messages `/api/chat` takes.
///
/// SandSeek uses `/api/chat` and not Ollama's OpenAI-compatible route,
/// because only `/api/chat` can set the context size of a request
/// (`options.num_ctx`) and switch reasoning (`think`). Ollama's default
/// context on a Mac is small (4,096 tokens on less than 24 GB of memory),
/// far too small for research.
public enum ResearchOllama {
    /// The context window a run asks for unless the model's trained maximum
    /// is smaller or `--context-tokens` says otherwise.
    public static let defaultContextTokens = 32_768
    /// The values `--context-tokens` accepts.
    public static let contextTokensRange = 4_096...262_144
    /// Time to wait for `/api/show`, which answers at once.
    public static let showTimeout: TimeInterval = 15

    // MARK: - Model names

    /// A name Ollama sends to ollama.com: ending in `:cloud` or `-cloud`.
    /// Ollama itself reads these suffixes as "run this model remotely".
    public static func isCloudModelName(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasSuffix(":cloud") || lowered.hasSuffix("-cloud")
    }

    /// Why a cloud model is not used. The question stays on this Mac.
    public static func cloudRefusal(_ name: String) -> String {
        "SandSeek keeps your question on this Mac; \(name) is an Ollama cloud model "
            + "that runs on ollama.com. Choose a model that runs on this Mac."
    }

    static let noDefaultModelMessage =
        "Ollama has no default model. Name one with --model, such as --model <name> "
        + "(`ollama list` shows the installed models)."

    /// The refusals that need no request: no model named, or a cloud name.
    /// Nil when the name may be tried.
    public static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "default" { return noDefaultModelMessage }
        if isCloudModelName(trimmed) { return cloudRefusal(trimmed) }
        return nil
    }

    // MARK: - Routes

    /// A route of the server. The server URL may end in `/v1`, as for chat.
    static func endpoint(_ serverURL: URL, _ path: String) -> URL? {
        var base = serverURL.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + path)
    }

    // MARK: - What /api/show says

    /// What `POST /api/show` says about a model, as far as SandSeek uses it.
    public struct ModelInfo: Equatable, Sendable {
        /// The model's `capabilities` (`completion`, `tools`, `thinking`,
        /// `embedding`, ...), or nil when the server does not list them.
        public let capabilities: [String]?
        /// True for a cloud model: Ollama gives it a non-empty `remote_host`.
        public let isCloud: Bool
        /// The context length the model was trained for, from the
        /// `model_info` key that ends in `.context_length`.
        public let trainedContextTokens: Int?

        public init(capabilities: [String]?, isCloud: Bool, trainedContextTokens: Int?) {
            self.capabilities = capabilities
            self.isCloud = isCloud
            self.trainedContextTokens = trainedContextTokens
        }

        /// False only when the server lists capabilities and `tools` is not
        /// one of them. A server that lists none (an older Ollama) gets the
        /// benefit of the doubt.
        public var canCallTools: Bool {
            guard let capabilities else { return true }
            return capabilities.contains("tools")
        }
    }

    /// Reads an `/api/show` answer. The trained context is the value of
    /// `<architecture>.context_length` when `general.architecture` names the
    /// architecture, else the smallest value of any key ending in
    /// `.context_length`.
    public static func modelInfo(fromShow show: ResearchJSON) -> ModelInfo {
        let capabilities = show["capabilities"]?.arrayValue?.compactMap(\.stringValue)
        let host = show["remote_host"]?.stringValue ?? ""
        var trained: Int?
        if let info = show["model_info"]?.objectValue {
            let positive = info.compactMap { key, value -> (String, Int)? in
                guard key.hasSuffix(".context_length"),
                      let tokens = value.intValue, tokens > 0 else { return nil }
                return (key, tokens)
            }
            if let architecture = info["general.architecture"]?.stringValue,
               let match = positive.first(where: { $0.0 == architecture + ".context_length" }) {
                trained = match.1
            } else {
                trained = positive.map { $0.1 }.min()
            }
        }
        return ModelInfo(capabilities: capabilities, isCloud: !host.isEmpty,
                         trainedContextTokens: trained)
    }

    /// The `num_ctx` a run asks for: `requested` (`--context-tokens`) when
    /// given; else 32,768, or the model's trained maximum when that is
    /// smaller.
    public static func contextTokens(requested: Int?, trained: Int?) -> Int {
        if let requested { return requested }
        guard let trained else { return defaultContextTokens }
        return min(defaultContextTokens, trained)
    }

    /// Asks `/api/show` about a model. Throws the error the run reports:
    /// `modelUnavailable` for a server that does not answer,
    /// `redirectRefused` for a 3xx, `invalidEndpoint` with the way out for a
    /// model that is not installed (404), `modelRequestFailed` for any other
    /// refusal.
    public static func show(model: String,
                            serverURL: URL,
                            transport: any ResearchHTTPTransport,
                            timeout: TimeInterval = showTimeout) async throws -> ModelInfo {
        guard let url = endpoint(serverURL, "/api/show") else {
            throw ResearchError.invalidEndpoint("the server address cannot be extended to /api/show")
        }
        let body = try ResearchJSON.object(["model": .string(model)]).encoded()
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "POST", url: url, body: body, timeout: timeout)
        } catch let error as URLError where error.code == .timedOut {
            throw ResearchError.modelUnavailable("no answer within \(Int(timeout)) seconds")
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw ResearchError.modelUnavailable(error.localizedDescription)
        }
        if response.isRedirect { throw ResearchError.redirectRefused(status: response.status) }
        let reply = try? ResearchJSON.decode(response.body)
        guard response.status == 200 else {
            if response.status == 404 {
                throw ResearchError.invalidEndpoint(
                    "the model \(model) is not installed in Ollama. Install it with "
                        + "`ollama pull \(model)` (`ollama list` shows the installed models).")
            }
            throw ResearchError.modelRequestFailed(
                status: response.status,
                message: errorText(reply, body: response.body),
                code: nil)
        }
        guard let reply, reply.objectValue != nil else {
            throw ResearchError.malformedModelReply("Ollama's /api/show answer is not a JSON object")
        }
        return modelInfo(fromShow: reply)
    }

    /// Checks the model and chooses the context window of an Ollama run:
    /// no model named, a cloud name, a model that is not installed, a cloud
    /// model (it has a `remote_host`) and a model that cannot call tools are
    /// refused with a message that says why. Returns the connection with the
    /// `num_ctx` that every request of the run asks for, which is also the
    /// run's known context budget. A connection of another kind comes back
    /// unchanged.
    ///
    /// The name checks run before any request is sent.
    public static func prepare(_ connection: ResearchServerConnection,
                               model: String,
                               requestedContextTokens: Int?,
                               serverURL: URL,
                               transport: any ResearchHTTPTransport) async throws
        -> ResearchServerConnection {
        guard connection.kind == .ollama else { return connection }
        if let problem = nameProblem(model) { throw ResearchError.invalidEndpoint(problem) }
        let info = try await show(model: model, serverURL: serverURL, transport: transport)
        if info.isCloud { throw ResearchError.invalidEndpoint(cloudRefusal(model)) }
        guard info.canCallTools else {
            let listed = (info.capabilities ?? []).joined(separator: ", ")
            throw ResearchError.invalidEndpoint(
                "the model \(model) cannot call tools (Ollama lists its capabilities as: "
                    + "\(listed.isEmpty ? "none" : listed)), and SandSeek's research needs a model "
                    + "that can. Choose another model, or install one with tool support "
                    + "(`ollama pull <name>`).")
        }
        return connection.withContextTokens(
            contextTokens(requested: requestedContextTokens, trained: info.trainedContextTokens))
    }

    // MARK: - Errors

    /// The text of Ollama's `{"error":"..."}` answer. It is a plain string,
    /// not an object as in the OpenAI-style error. An object with a
    /// `message` is read too; anything else is the start of the body.
    static func errorText(_ reply: ResearchJSON?, body: Data) -> String {
        if let error = reply?["error"] {
            if let text = error.stringValue { return text }
            if let text = error["message"]?.stringValue { return text }
        }
        return String(decoding: body.prefix(500), as: UTF8.self)
    }

    /// Whether an Ollama error says the prompt does not fit the context
    /// window. With `truncate: false` Ollama refuses such a request, and the
    /// loop shortens the conversation when the error has the code
    /// `context_length_exceeded`, so this maps the wording onto that code.
    static func isContextOverflow(_ message: String) -> Bool {
        let lowered = message.lowercased()
        guard lowered.contains("context") || lowered.contains("prompt is too long") else {
            return false
        }
        return ["longer than", "exceed", "too large", "too long", "does not fit"]
            .contains { lowered.contains($0) }
    }

    /// The error for a refusal from Ollama. `status` is the HTTP status, or
    /// nil for an error inside a stream, which has none: the loop retries a
    /// status of 500 or more once without reasoning, so such an error is
    /// given 500, and a request that does not fit the context 400.
    static func failure(_ error: ResearchJSON, status: Int?) -> ResearchError {
        let message = error.stringValue
            ?? error["message"]?.stringValue
            ?? String(String(describing: error).prefix(500))
        return failure(message: message, status: status ?? 500)
    }

    static func failure(message: String, status: Int) -> ResearchError {
        if isContextOverflow(message) {
            return .modelRequestFailed(
                status: min(status, 400), message: message, code: "context_length_exceeded")
        }
        return .modelRequestFailed(status: status, message: message, code: nil)
    }

    // MARK: - Messages

    /// The loop's OpenAI-style messages as `/api/chat` takes them:
    /// - an assistant message's `tool_calls[].function.arguments`, a JSON
    ///   string, becomes the JSON object it holds; the call's `id` stays;
    /// - a tool result gets `tool_name` when an earlier call with that
    ///   `tool_call_id` named the tool;
    /// - an earlier turn's `reasoning_content` becomes `thinking`;
    /// - an assistant message without text gets `content: ""`.
    /// System and user messages are passed on as they are.
    static func messages(from messages: [ResearchJSON]) -> [ResearchJSON] {
        var toolNames: [String: String] = [:]
        var translated: [ResearchJSON] = []
        for message in messages {
            guard case .object(var fields) = message else {
                translated.append(message)
                continue
            }
            switch fields["role"]?.stringValue {
            case "assistant"?:
                if let reasoning = fields.removeValue(forKey: "reasoning_content")?.stringValue,
                   !reasoning.isEmpty {
                    fields["thinking"] = .string(reasoning)
                }
                if fields["content"]?.stringValue == nil { fields["content"] = .string("") }
                if let calls = fields["tool_calls"]?.arrayValue {
                    var converted: [ResearchJSON] = []
                    for (index, call) in calls.enumerated() {
                        let name = call["function"]?["name"]?.stringValue ?? ""
                        var entry: [String: ResearchJSON] = [
                            "function": .object([
                                "index": .integer(index),
                                "name": .string(name),
                                "arguments": argumentsObject(call["function"]?["arguments"]),
                            ]),
                        ]
                        if let id = call["id"]?.stringValue {
                            entry["id"] = .string(id)
                            toolNames[id] = name
                        }
                        converted.append(.object(entry))
                    }
                    fields["tool_calls"] = .array(converted)
                }
            case "tool"?:
                if let id = fields["tool_call_id"]?.stringValue, let name = toolNames[id] {
                    fields["tool_name"] = .string(name)
                }
            default:
                break
            }
            translated.append(.object(fields))
        }
        return translated
    }

    /// A tool call's arguments as the JSON object Ollama wants. The loop
    /// keeps them as a JSON object string; anything that is not an object
    /// becomes the empty object.
    static func argumentsObject(_ arguments: ResearchJSON?) -> ResearchJSON {
        guard let arguments else { return .object([:]) }
        switch arguments {
        case .object:
            return arguments
        case .string(let text):
            if let decoded = try? ResearchJSON.decode(Data(text.utf8)),
               decoded.objectValue != nil {
                return decoded
            }
            return .object([:])
        default:
            return .object([:])
        }
    }
}

/// Hands out the numbers of the ids `call_<n>` that are given to tool calls
/// the server sent without an id, so that no two calls of a run share one.
final class ResearchCallNumbering: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1

    /// The number the next call without an id gets.
    var current: Int { lock.withLock { next } }

    /// Moves past the numbers a turn may have used.
    func advance(by count: Int) {
        lock.withLock { next += max(0, count) }
    }
}
