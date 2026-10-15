import Foundation

/// The kind of model server SandSeek talks to. Each kind has its own
/// connector: what to send, how it reports its limits, how its errors are
/// named. A server without a connector is not used, however "OpenAI
/// compatible" it says it is.
public enum ResearchServerKind: String, Equatable, Sendable {
    case tuff
    case llamacpp
    case ollama

    public var displayName: String {
        switch self {
        case .tuff: "TUFF"
        case .llamacpp: "llama.cpp"
        case .ollama: "Ollama"
        }
    }
}

/// What `--server-type` asks for. `auto` asks the server which kind it is.
public enum ResearchServerChoice: String, Equatable, Sendable {
    case auto
    case tuff
    case llamacpp
    case ollama
}

/// What `GET /tuff/v1/status` told about the server.
public enum ResearchServerProbe: Equatable, Sendable {
    /// A 200 with a JSON object: TUFF. `version` is its `version` when it has one.
    case tuff(version: String?)
    /// The server answered, but not like TUFF's status route.
    case other(status: Int)
    /// The server did not answer.
    case unreachable(String)
}

/// What `GET /api/version` told about the server.
public enum ResearchOllamaProbe: Equatable, Sendable {
    /// A 200 with a JSON object that has a string `version`: Ollama.
    case ollama(version: String)
    /// The server answered, but not like Ollama's version route.
    case other(status: Int)
    /// The server did not answer.
    case unreachable(String)
}

/// The server a run talks to, after detection, and how.
public struct ResearchServerConnection: Equatable, Sendable {
    public let kind: ResearchServerKind
    /// The version the server reported, when it did.
    public let version: String?
    /// Whether model replies are read as a stream.
    public let streaming: Bool
    /// Something the run should say before it starts, such as a server that
    /// was named as TUFF but did not answer TUFF's status route.
    public let warning: String?
    /// The model's context window in tokens when the server says it outside
    /// the model list: llama.cpp's `/props` (`default_generation_settings.n_ctx`).
    /// For Ollama it is the `num_ctx` every request asks for. Nil when it is
    /// not known; the run then follows the model list, or its small fallback
    /// budget.
    public let contextTokens: Int?
    /// For Ollama, after `ResearchOllama.prepare`: whether the model lists
    /// `thinking` among its capabilities. Nil when it is not known (not
    /// checked yet, or the server lists no capabilities).
    public let thinkingSupported: Bool?

    public init(kind: ResearchServerKind, version: String?, streaming: Bool,
                warning: String? = nil, contextTokens: Int? = nil,
                thinkingSupported: Bool? = nil) {
        self.kind = kind
        self.version = version
        self.streaming = streaming
        self.warning = warning
        self.contextTokens = contextTokens
        self.thinkingSupported = thinkingSupported
    }

    /// The one progress line a run prints before it starts.
    public var progressLine: String { progressLine(enableThinking: nil) }

    /// The same line for a run whose request carries `think` as
    /// `enableThinking` (see `ResearchOllama.thinking`): for Ollama it ends
    /// with `thinking on` or `thinking off`, because an unset switch means
    /// off there, unlike TUFF, where it means the model's own choice. Nil
    /// (no `think` is sent) adds nothing.
    public func progressLine(enableThinking: Bool?) -> String {
        var line = "server: " + kind.displayName
        if let version, !version.isEmpty { line += " " + version }
        switch kind {
        case .tuff:
            line += streaming ? ", streaming" : ", no streaming"
        case .llamacpp:
            line += ", no streaming (llama.cpp gets plain requests)"
        case .ollama:
            line += streaming ? ", streaming" : ", no streaming"
            if let contextTokens { line += ", context \(contextTokens) tokens" }
            if let enableThinking { line += enableThinking ? ", thinking on" : ", thinking off" }
        }
        return line
    }

    /// The same connection with the context window the run will ask for.
    public func withContextTokens(_ tokens: Int?) -> ResearchServerConnection {
        ResearchServerConnection(kind: kind, version: version, streaming: streaming,
                                 warning: warning, contextTokens: tokens,
                                 thinkingSupported: thinkingSupported)
    }

    /// The same connection with what `/api/show` said about the model.
    public func withModel(contextTokens tokens: Int?,
                          thinkingSupported: Bool?) -> ResearchServerConnection {
        ResearchServerConnection(kind: kind, version: version, streaming: streaming,
                                 warning: warning, contextTokens: tokens,
                                 thinkingSupported: thinkingSupported)
    }

    /// TUFF's status route. The server URL may end in `/v1`, as for chat.
    static func statusURL(for serverURL: URL) -> URL? {
        var base = serverURL.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/tuff/v1/status")
    }

    /// Asks the server whether it is TUFF. A short time limit: a server that
    /// is up answers at once.
    public static func probe(serverURL: URL,
                             transport: any ResearchHTTPTransport,
                             timeout: TimeInterval = 5) async -> ResearchServerProbe {
        guard let url = statusURL(for: serverURL) else {
            return .unreachable("the server address cannot be extended to /tuff/v1/status")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: url, body: nil, timeout: timeout)
        } catch let error as URLError where error.code == .timedOut {
            return .unreachable("no answer within \(Int(timeout)) seconds")
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard response.status == 200,
              let status = try? ResearchJSON.decode(response.body),
              status.objectValue != nil else {
            return .other(status: response.status)
        }
        let version = status["version"]?.stringValue
        return .tuff(version: version?.isEmpty == false ? version : nil)
    }

    /// Ollama's version route. The server URL may end in `/v1`, as for chat.
    static func ollamaVersionURL(for serverURL: URL) -> URL? {
        var base = serverURL.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/api/version")
    }

    /// Asks the server whether it is Ollama (`GET /api/version`, which answers
    /// `{"version":"0.x.y"}`). A short time limit, as for `probe`.
    public static func probeOllama(serverURL: URL,
                                   transport: any ResearchHTTPTransport,
                                   timeout: TimeInterval = 5) async -> ResearchOllamaProbe {
        guard let url = ollamaVersionURL(for: serverURL) else {
            return .unreachable("the server address cannot be extended to /api/version")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: url, body: nil, timeout: timeout)
        } catch let error as URLError where error.code == .timedOut {
            return .unreachable("no answer within \(Int(timeout)) seconds")
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard response.status == 200,
              let status = try? ResearchJSON.decode(response.body),
              status.objectValue != nil,
              let version = status["version"]?.stringValue else {
            return .other(status: response.status)
        }
        return .ollama(version: version)
    }

    /// Decides which server this is and whether to stream.
    ///
    /// - `auto`: TUFF when the status route says so, else Ollama when its
    ///   version route says so. Anything else is refused, with the way out:
    ///   llama.cpp must be named, because it is not detected.
    /// - `tuff`: used as named. The status route is asked once, to record the
    ///   version. A server that does not answer at all is an error, as for
    ///   `auto`. Every TUFF 8.3.1 server has the route (the Background API and
    ///   `tuff serve` run the same server), so an answer that is not TUFF's
    ///   only gives a warning: the run goes on as TUFF because it was named.
    /// - `llamacpp`: used as named, with today's plain request. It cannot
    ///   stream before its connector exists (`stream` on is refused).
    /// - `ollama`: the version route is asked once. A server that does not
    ///   answer is an error, and so is one that answers but is not Ollama:
    ///   Ollama is never assumed.
    ///
    /// `stream` is the `--stream` choice; nil is the default, which is on for
    /// TUFF and Ollama and off for llama.cpp. The context window of an Ollama
    /// connection is added later (`ResearchOllama.prepare`), because it
    /// depends on the model.
    public static func establish(choice: ResearchServerChoice,
                                 stream: Bool?,
                                 serverURL: URL,
                                 transport: any ResearchHTTPTransport) async throws
        -> ResearchServerConnection {
        switch choice {
        case .llamacpp:
            if stream == true {
                throw ResearchError.invalidEndpoint(streamingNeedsConnectorMessage)
            }
            return ResearchServerConnection(kind: .llamacpp, version: nil, streaming: false)
        case .ollama:
            switch await probeOllama(serverURL: serverURL, transport: transport) {
            case .ollama(let version):
                return ResearchServerConnection(
                    kind: .ollama, version: version, streaming: stream ?? true)
            case .unreachable(let message):
                throw ResearchError.modelUnavailable(message)
            case .other(let status) where (300..<400).contains(status):
                throw ResearchError.redirectRefused(status: status)
            case .other(let status):
                throw ResearchError.invalidEndpoint(notOllamaMessage(serverURL: serverURL, status: status))
            }
        case .tuff:
            switch await probe(serverURL: serverURL, transport: transport) {
            case .tuff(let version):
                return ResearchServerConnection(
                    kind: .tuff, version: version, streaming: stream ?? true)
            case .unreachable(let message):
                throw ResearchError.modelUnavailable(message)
            case .other(let status) where (300..<400).contains(status):
                // Not "continue as TUFF": the port is answered by something
                // that redirects, which TUFF never does.
                throw ResearchError.redirectRefused(status: status)
            case .other(let status):
                return ResearchServerConnection(
                    kind: .tuff, version: nil, streaming: stream ?? true,
                    warning: "the server did not answer TUFF's /tuff/v1/status (HTTP \(status)); "
                        + "continuing as TUFF because --server-type tuff was given")
            }
        case .auto:
            let probed = await probe(serverURL: serverURL, transport: transport)
            switch probed {
            case .tuff(let version):
                return ResearchServerConnection(
                    kind: .tuff, version: version, streaming: stream ?? true)
            case .unreachable(let message):
                throw ResearchError.modelUnavailable(message)
            case .other(let status) where (300..<400).contains(status):
                throw ResearchError.redirectRefused(status: status)
            case .other(let status):
                // Not TUFF: it may be Ollama, which has its own version route.
                if case .ollama(let version) = await probeOllama(
                    serverURL: serverURL, transport: transport) {
                    return ResearchServerConnection(
                        kind: .ollama, version: version, streaming: stream ?? true)
                }
                throw ResearchError.invalidEndpoint(notTUFFMessage(serverURL: serverURL, status: status))
            }
        }
    }

    static let streamingNeedsConnectorMessage =
        "--stream on needs a server with streaming. --server-type llamacpp is "
        + "experimental and sends plain (non-streaming) requests."

    static func notTUFFMessage(serverURL: URL, status: Int) -> String {
        "the server at \(serverURL.absoluteString) did not answer TUFF's /tuff/v1/status "
            + "(HTTP \(status)) or Ollama's /api/version, so it is not recognised. For a llama.cpp server "
            + "(llama-server) pass --server-type llamacpp: it is experimental and gets "
            + "plain (non-streaming) requests. For Ollama, start it with `ollama serve` and "
            + "pass --server-type ollama. For TUFF, start its Background API (or `tuff serve`), which "
            + "has the status route, or pass --server-type tuff."
    }

    static func notOllamaMessage(serverURL: URL, status: Int) -> String {
        "the server at \(serverURL.absoluteString) did not answer Ollama's /api/version "
            + "(HTTP \(status)), so it is not Ollama. For TUFF pass --server-type tuff; for a "
            + "llama.cpp server (llama-server) pass --server-type llamacpp."
    }
}
