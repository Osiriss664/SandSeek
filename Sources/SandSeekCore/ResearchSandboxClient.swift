import Foundation

public struct ResearchSearchResult: Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
}

/// One paragraph of a page, with where it stands in the page's text, in
/// Unicode scalars.
public struct ResearchPassage: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String
    /// The paragraph's number among the page's paragraphs, in page order.
    /// Two passages whose numbers differ by one stood next to each other.
    public var index: Int = -1

    /// Whether `other` follows this passage directly on the page.
    func isFollowed(by other: ResearchPassage) -> Bool {
        index >= 0 && other.index == index + 1
    }
}

public struct ResearchPageSlice: Equatable, Sendable {
    public let url: String
    public let title: String
    public let text: String
    /// Where the slice starts. For a passage read, the number of passages
    /// given before it, best first, not a character position.
    public let offset: Int
    public let nextOffset: Int?
    public let totalCharacters: Int
    /// The passages of a passage read, in page order. Nil for a read of
    /// characters from front to back.
    public var passages: [ResearchPassage]? = nil
    /// How many passages the page has, set with `passages`.
    public var passageCount: Int? = nil
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

    /// What the user is told when the sandbox cannot rank passages.
    public static let passagesUnsupportedMessage =
        "The web sandbox is older than this TUFF and cannot rank passages. Rebuild it "
        + "(Scripts/research_sandbox.sh build), or turn off 'Read the passages that best "
        + "match the question first' (--passages off)."

    /// Checks that the sandbox answers. With `requirePassages`, it must also
    /// say it can rank passages, which an older sandbox does not.
    public func checkHealth(requirePassages: Bool = false) async throws {
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
        if requirePassages {
            let reply = try? ResearchJSON.decode(response.body)
            guard reply?["passages"] == .bool(true) else {
                throw ResearchError.sandboxCannotRankPassages
            }
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

    /// Reads a page. With `passages`, the sandbox ranks the page's paragraphs
    /// against `query` (BM25) and returns the best ones that fit
    /// `maxCharacters`; `offset` then counts the passages already given. The
    /// ranking happens there, so only text comes back.
    public func fetch(url: String, offset: Int, maxCharacters: Int,
                      passages: Bool = false, query: String = "") async throws -> ResearchPageSlice {
        var fields: [String: ResearchJSON] = [
            "url": .string(url),
            "offset": .integer(offset),
            "max_chars": .integer(maxCharacters),
        ]
        if passages {
            fields["passages"] = .bool(true)
            fields["query"] = .string(query)
        }
        let reply = try await post("v1/fetch", fields)
        guard let finalURL = reply["url"]?.stringValue,
              let text = reply["text"]?.stringValue else {
            throw ResearchToolFailure(message: "the sandbox returned an unreadable page")
        }
        var slice = ResearchPageSlice(
            url: finalURL,
            title: reply["title"]?.stringValue ?? "",
            text: text,
            offset: reply["offset"]?.intValue ?? offset,
            nextOffset: reply["next_offset"]?.intValue,
            totalCharacters: reply["total_chars"]?.intValue ?? text.count)
        if passages {
            // A passage read must come back as one; an older sandbox that
            // ignores the request would otherwise be read as characters.
            guard reply["mode"]?.stringValue == "passages",
                  let parts = reply["passages"]?.arrayValue else {
                throw ResearchToolFailure(message: Self.passagesUnsupportedMessage)
            }
            slice.passages = parts.map { part in
                ResearchPassage(start: part["start"]?.intValue ?? 0,
                                end: part["end"]?.intValue ?? 0,
                                text: part["text"]?.stringValue ?? "",
                                index: part["index"]?.intValue ?? -1)
            }
            slice.passageCount = reply["passage_count"]?.intValue ?? parts.count
        }
        return slice
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
