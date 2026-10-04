import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ResearchHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// One JSON POST or GET to a loopback service. Tests replace it with a fake;
/// the command uses `URLSessionResearchTransport`.
public protocol ResearchHTTPTransport: Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse
}

public struct URLSessionResearchTransport: ResearchHTTPTransport {
    private let session: URLSession

    /// Model turns can take minutes on large streamed models: Qwen3.6 35B
    /// on a 16 GB Mac needed 858 s for one turn that reasoned for its whole
    /// token limit. So the request timeout is generous; the sandbox enforces
    /// its own fetch timeouts.
    public init(timeout: TimeInterval = 1_800) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // Both services are on loopback. A system proxy must never see them.
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    public func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ResearchHTTPResponse(status: status, body: data)
    }
}

public enum ResearchError: Error, Equatable, CustomStringConvertible {
    case invalidEndpoint(String)
    case modelUnavailable(String)
    /// One model turn took longer than the request timeout.
    case modelTimedOut
    case modelRequestFailed(status: Int, message: String, code: String?)
    case malformedModelReply(String)
    case sandboxUnavailable(String)
    /// The model ended a turn with neither an answer nor a tool call, twice.
    case noAnswer(tokenLimit: Bool)

    public var description: String {
        switch self {
        case .invalidEndpoint(let message):
            message
        case .modelUnavailable(let message):
            "could not reach the TUFF server: \(message). Start it with `tuff serve` "
                + "or enable the Background API in TUFF's Server screen."
        case .modelTimedOut:
            "one model step took longer than the request time limit. The model may be too "
                + "slow on this Mac for this question; try fewer steps, or thinking off."
        case .modelRequestFailed(let status, let message, _):
            "the TUFF server refused the request (HTTP \(status)): \(message)"
        case .malformedModelReply(let message):
            "the TUFF server sent a reply the research loop cannot read: \(message)"
        case .sandboxUnavailable(let message):
            "could not reach the web research sandbox: \(message). "
                + "Start it with `Scripts/research_sandbox.sh start`."
        case .noAnswer(tokenLimit: true):
            "the model used its whole token limit before writing an answer, usually by "
                + "thinking. Try a larger --max-tokens, or --thinking off."
        case .noAnswer(tokenLimit: false):
            "the model ended without writing an answer. Try again, or try another model."
        }
    }
}

public enum ResearchEndpoint {
    /// Both services must be plain HTTP on this Mac's loopback address. The
    /// TUFF server has no authentication and must stay local, and the sandbox
    /// is published only to loopback.
    public static func loopbackURL(_ text: String, flag: String) throws -> URL {
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil
        else {
            throw ResearchError.invalidEndpoint(
                "\(flag) must be an http URL on 127.0.0.1, localhost or ::1, such as "
                    + "http://127.0.0.1:8080")
        }
        var trimmed = url.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)!
    }
}
