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
    /// The sandbox's HTTP status for a failed request, when it had one.
    public var status: Int? = nil

    /// The HTTP status a site answered with, as the sandbox reports it in
    /// its message (`... answered HTTP 403`).
    static func siteStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"answered HTTP (\d{3})"#, options: .regularExpression)
        else { return nil }
        return Int(message[range].suffix(3))
    }

    /// Statuses that mean the site turned the reader away.
    var siteRefused: Bool { [401, 403, 429, 451].contains(status ?? 0) }
}

/// When a client last proved, with a signed health check, that it is talking
/// to the sandbox. The client is a value that is copied around; its copies share
/// one of these, so a proof one copy made counts for all.
public final class ResearchSandboxProof: @unchecked Sendable {
    private let lock = NSLock()
    private var provedAt: Date?

    public init() {}

    /// Whether a proof was made at most `maxAge` seconds before `now`. A proof
    /// dated after `now` (the clock moved back) is no proof.
    func isFresh(now: Date, maxAge: TimeInterval) -> Bool {
        lock.withLock { () -> Bool in
            guard let provedAt else { return false }
            let age = now.timeIntervalSince(provedAt)
            return age >= 0 && age <= maxAge
        }
    }

    func record(at date: Date) {
        lock.withLock { provedAt = date }
    }

    func forget() {
        lock.withLock { provedAt = nil }
    }
}

/// Client for the web tool server running in the Apple container sandbox.
///
/// Every request is signed with the secret in `secretFile` and every answer
/// is checked against it before anything in it is used (see
/// `ResearchSandboxSigning`). Without the file nothing is sent. A search or a
/// read that comes more than `identityMaxAge` seconds after the last signed
/// health check is preceded by one, so a sandbox that was replaced by another
/// program during a pause (a model turn can take minutes) is noticed before
/// the request, and its text, goes anywhere.
public struct ResearchSandboxClient: Sendable {
    /// How long a signed health check vouches for the sandbox.
    static let identityMaxAge: TimeInterval = 5

    public let baseURL: URL
    private let transport: any ResearchHTTPTransport
    private let secretFile: URL
    private let makeNonce: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let proof: ResearchSandboxProof

    /// `secretFile` is where the launcher writes the secret (see
    /// `ResearchSandboxSecret`; the app passes `ResearchSandboxSecret.defaultFileURL`).
    /// `now` is the clock for the request time and for the health check's age.
    /// `proof` is shared by copies of the client; a new one is made by default.
    public init(baseURL: URL, transport: any ResearchHTTPTransport, secretFile: URL,
                makeNonce: @escaping @Sendable () -> String = { ResearchSandboxSecret.randomNonce() },
                now: @escaping @Sendable () -> Date = { Date() },
                proof: ResearchSandboxProof = ResearchSandboxProof()) {
        self.baseURL = baseURL
        self.transport = transport
        self.secretFile = secretFile
        self.makeNonce = makeNonce
        self.now = now
        self.proof = proof
    }

    /// What the user is told when the sandbox cannot rank passages.
    public static let passagesUnsupportedMessage =
        "The web sandbox is older than this version of SandSeek and cannot rank passages. Rebuild it "
        + "(Scripts/research_sandbox.sh build), or turn off 'Read the passages that best "
        + "match the question first' (--passages off)."

    /// Checks that the sandbox answers, signed, with `status` `ok` and API 1. With
    /// `requirePassages`, it must also say it can rank passages. A health check
    /// that passes is the proof of identity that `search` and `fetch` rely on.
    public func checkHealth(requirePassages: Bool = false) async throws {
        // A 3xx is never followed (see `ResearchNoRedirectDelegate`) and is an
        // error here, as every other answer but 200.
        let response = try await exchange(method: "GET", path: "health", body: nil)
        guard response.status == 200 else {
            throw ResearchError.sandboxUnavailable("health check answered HTTP \(response.status)")
        }
        let reply = try? ResearchJSON.decode(response.body)
        guard reply?["status"]?.stringValue == "ok" else {
            throw ResearchError.sandboxUnavailable("health check did not say the sandbox is ok")
        }
        guard reply?["api"]?.intValue == 1 else { throw ResearchError.sandboxWrongVersion }
        if requirePassages {
            guard reply?["passages"] == .bool(true) else {
                throw ResearchError.sandboxCannotRankPassages
            }
        }
        proof.record(at: now())
    }

    /// A signed health check first, unless one passed in the last few seconds.
    private func proveIdentityIfStale() async throws {
        guard !proof.isFresh(now: now(), maxAge: Self.identityMaxAge) else { return }
        try await checkHealth()
    }

    public func search(query: String, maxResults: Int) async throws -> [ResearchSearchResult] {
        let reply = try await post("v1/search", [
            "query": .string(query),
            "max_results": .integer(maxResults),
        ])
        return (reply["results"]?.arrayValue ?? []).compactMap { item in
            // The sandbox only ever returns http and https addresses; anything
            // else came from something that is not the sandbox, and a result
            // with it is dropped.
            guard let url = item["url"]?.stringValue, ResearchText.isWebURL(url) else { return nil }
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
        // The address becomes a source in the report. The sandbox only ever
        // reads http and https pages; a `javascript:` or `file:` address
        // would be a link in the saved report.
        guard ResearchText.isWebURL(finalURL) else {
            throw ResearchToolFailure(
                message: "the sandbox returned a page address that is not http or https")
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
        let body: Data
        do {
            body = try ResearchJSON.object(fields).encoded()
        } catch {
            throw ResearchError.sandboxUnavailable(error.localizedDescription)
        }
        try await proveIdentityIfStale()
        let response = try await exchange(method: "POST", path: path, body: body)
        let reply = try? ResearchJSON.decode(response.body)
        guard response.status == 200, let reply else {
            let message = reply?["error"]?["message"]?.stringValue
                ?? "the sandbox answered HTTP \(response.status)"
            // The sandbox answers 502 when the site itself answered an error
            // ("<url> answered HTTP 403"); that status is the one that counts.
            throw ResearchToolFailure(
                message: message, status: ResearchToolFailure.siteStatus(in: message)
                    ?? response.status)
        }
        return reply
    }

    /// One signed request and its answer. A 3xx is refused first: its body is
    /// never read, since nothing that answers with a 3xx is the sandbox, so
    /// nothing in it is passed on to the model. Then the answer's signature is
    /// checked, whatever its status, before anything in it is used. The secret
    /// is read for every request, and a missing one stops it here.
    private func exchange(method: String, path: String, body: Data?) async throws -> ResearchHTTPResponse {
        // The path that is signed is the one that is sent.
        let url = baseURL.appendingPathComponent(path)
        let signing = try ResearchSandboxSigning.begin(
            secretFile: secretFile, method: method, path: url.path, now: now(), makeNonce: makeNonce)
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: method, url: url, body: body, timeout: nil, authorization: nil,
                headers: signing.requestHeaders(body: body ?? Data()))
        } catch {
            throw ResearchError.sandboxUnavailable(error.localizedDescription)
        }
        if response.isRedirect {
            proof.forget()
            throw ResearchError.redirectRefused(status: response.status)
        }
        guard signing.isValid(response) else {
            proof.forget()
            throw ResearchError.sandboxNotSigned(address: address)
        }
        return response
    }

    /// The sandbox's host and port for a message, such as `127.0.0.1:9100`.
    private var address: String {
        let host = baseURL.host ?? "127.0.0.1"
        return (host.contains(":") ? "[\(host)]" : host) + ":" + String(baseURL.port ?? 80)
    }
}
