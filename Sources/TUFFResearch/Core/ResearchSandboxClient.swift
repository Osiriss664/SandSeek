import Foundation

public struct ResearchSearchResult: Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
}

public struct ResearchPageSlice: Equatable, Sendable {
    public let url: String
    public let title: String
    public let text: String
    public let offset: Int
    public let nextOffset: Int?
    public let totalCharacters: Int
}

/// A tool failure the model should hear about, such as a blocked address or
/// a 404. It becomes the tool result instead of ending the research run.
public struct ResearchToolFailure: Error, Equatable, Sendable {
    public let message: String
}

/// Client for the web tool server running in the Apple container sandbox.
public struct ResearchSandboxClient: Sendable {
    public let baseURL: URL
    private let transport: any ResearchHTTPTransport

    public init(baseURL: URL, transport: any ResearchHTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func checkHealth() async throws {
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: baseURL.appendingPathComponent("health"), body: nil)
        } catch {
            throw ResearchError.sandboxUnavailable(error.localizedDescription)
        }
        guard response.status == 200 else {
            throw ResearchError.sandboxUnavailable("health check answered HTTP \(response.status)")
        }
    }

    public func search(query: String, maxResults: Int) async throws -> [ResearchSearchResult] {
        let reply = try await post("v1/search", [
            "query": .string(query),
            "max_results": .integer(maxResults),
        ])
        return (reply["results"]?.arrayValue ?? []).compactMap { item in
            guard let url = item["url"]?.stringValue else { return nil }
            return ResearchSearchResult(
                title: item["title"]?.stringValue ?? "",
                url: url,
                snippet: item["snippet"]?.stringValue ?? "")
        }
    }

    public func fetch(url: String, offset: Int, maxCharacters: Int) async throws -> ResearchPageSlice {
        let reply = try await post("v1/fetch", [
            "url": .string(url),
            "offset": .integer(offset),
            "max_chars": .integer(maxCharacters),
        ])
        guard let finalURL = reply["url"]?.stringValue,
              let text = reply["text"]?.stringValue else {
            throw ResearchToolFailure(message: "the sandbox returned an unreadable page")
        }
        return ResearchPageSlice(
            url: finalURL,
            title: reply["title"]?.stringValue ?? "",
            text: text,
            offset: reply["offset"]?.intValue ?? offset,
            nextOffset: reply["next_offset"]?.intValue,
            totalCharacters: reply["total_chars"]?.intValue ?? text.count)
    }

    private func post(_ path: String, _ fields: [String: ResearchJSON]) async throws -> ResearchJSON {
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "POST",
                url: baseURL.appendingPathComponent(path),
                body: try ResearchJSON.object(fields).encoded())
        } catch {
            throw ResearchError.sandboxUnavailable(error.localizedDescription)
        }
        let reply = try? ResearchJSON.decode(response.body)
        guard response.status == 200, let reply else {
            let message = reply?["error"]?["message"]?.stringValue
                ?? "the sandbox answered HTTP \(response.status)"
            throw ResearchToolFailure(message: message)
        }
        return reply
    }
}
