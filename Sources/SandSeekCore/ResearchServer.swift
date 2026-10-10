import Foundation

/// The kind of model server SandSeek talks to. Each kind has its own
/// connector: what to send, how it reports its limits, how its errors are
/// named. A server without a connector is not used, however "OpenAI
/// compatible" it says it is.
public enum ResearchServerKind: String, Equatable, Sendable {
    case tuff
    case llamacpp

    public var displayName: String {
        switch self {
        case .tuff: "TUFF"
        case .llamacpp: "llama.cpp"
        }
    }
}

/// What `--server-type` asks for. `auto` asks the server which kind it is.
public enum ResearchServerChoice: String, Equatable, Sendable {
    case auto
    case tuff
    case llamacpp
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
    /// Nil when it is not known; the run then follows the model list, or its
    /// small fallback budget.
    public let contextTokens: Int?

    public init(kind: ResearchServerKind, version: String?, streaming: Bool,
                warning: String? = nil, contextTokens: Int? = nil) {
        self.kind = kind
        self.version = version
        self.streaming = streaming
        self.warning = warning
        self.contextTokens = contextTokens
    }

    /// The one progress line a run prints before it starts.
    public var progressLine: String {
        var line = "server: " + kind.displayName
        if let version, !version.isEmpty { line += " " + version }
        switch kind {
        case .tuff:
            line += streaming ? ", streaming" : ", no streaming"
        case .llamacpp:
            line += ", no streaming (the llama.cpp connector comes in Abschnitt 2b)"
        }
        return line
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

    /// Decides which server this is and whether to stream.
    ///
    /// - `auto`: TUFF when the status route says so. Anything else is
    ///   refused, with the way out: llama.cpp must be named, because its
    ///   connector (Abschnitt 2b) is not detected yet.
    /// - `tuff`: used as named. The status route is asked once, to record the
    ///   version. A server that does not answer at all is an error, as for
    ///   `auto`. Every TUFF 8.3.1 server has the route (the Background API and
    ///   `tuff serve` run the same server), so an answer that is not TUFF's
    ///   only gives a warning: the run goes on as TUFF because it was named.
    /// - `llamacpp`: used as named, with today's plain request. It cannot
    ///   stream before its connector exists (`stream` on is refused).
    ///
    /// `stream` is the `--stream` choice; nil is the default, which is on for
    /// TUFF and off for llama.cpp.
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
        case .tuff:
            switch await probe(serverURL: serverURL, transport: transport) {
            case .tuff(let version):
                return ResearchServerConnection(
                    kind: .tuff, version: version, streaming: stream ?? true)
            case .unreachable(let message):
                throw ResearchError.modelUnavailable(message)
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
            case .other(let status):
                throw ResearchError.invalidEndpoint(notTUFFMessage(serverURL: serverURL, status: status))
            }
        }
    }

    static let streamingNeedsConnectorMessage =
        "--stream on needs a server connector with streaming. The llama.cpp connector "
        + "comes in Abschnitt 2b; until then --server-type llamacpp sends the plain "
        + "non-streaming request."

    static func notTUFFMessage(serverURL: URL, status: Int) -> String {
        "the server at \(serverURL.absoluteString) did not answer TUFF's /tuff/v1/status "
            + "(HTTP \(status)), so it is not recognised as TUFF. For a llama.cpp server "
            + "(llama-server) pass --server-type llamacpp: its connector comes in "
            + "Abschnitt 2b, and until then it gets today's non-streaming request "
            + "unchanged. For TUFF, start its Background API (or `tuff serve`), which "
            + "has the status route, or pass --server-type tuff."
    }
}
