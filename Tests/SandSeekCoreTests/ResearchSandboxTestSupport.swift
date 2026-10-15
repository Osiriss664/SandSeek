import Foundation
@testable import SandSeekCore

/// The secret that tests sign with: one file for the whole test run, written
/// the way the launcher writes it (64 hex characters, mode 0600).
enum TestSandboxSecret {
    static let text = String(repeating: "0123456789abcdef", count: 4)
    static let key = Data(text.utf8)

    static let file: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekTestSecret-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("secret")
        try! Data(text.utf8).write(to: file)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }()
}

/// Stands between the sandbox client and a fake that knows nothing about
/// signing: it passes the request on and signs the fake's answer the way the
/// real sandbox signs, from the nonce, method and path of the request. Where
/// CryptoKit is missing nothing can be signed, and the client refuses every
/// answer, as it does in the app.
struct SigningSandboxTransport: ResearchHTTPTransport {
    let inner: any ResearchHTTPTransport
    var key: Data = TestSandboxSecret.key

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await inner.send(method: method, url: url, body: body)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        let response = try await inner.send(
            method: method, url: url, body: body, timeout: timeout, authorization: authorization)
        guard let nonce = headers[ResearchSandboxSigning.nonceHeader] else { return response }
        var signed = response.headers
        signed[ResearchSandboxSigning.answerAuthHeader] = ResearchSandboxSigning.responseAuth(
            key: key, method: method, path: url.path, nonce: nonce,
            status: response.status, body: response.body)
        return ResearchHTTPResponse(status: response.status, body: response.body, headers: signed)
    }
}

extension ResearchSandboxClient {
    /// The time every test client sees, so that a signed health check "just
    /// passed" stays fresh however long the test takes.
    static let testTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// A client for tests of the research loop. Its answers are signed by
    /// `SigningSandboxTransport`, and with `identityProved` (the default) its
    /// last health check has just passed, so a search or a read does not send
    /// one first; the tests of that rule pass `false`.
    static func forTests(baseURL: URL, transport: any ResearchHTTPTransport,
                         identityProved: Bool = true) -> ResearchSandboxClient {
        let proof = ResearchSandboxProof()
        if identityProved { proof.record(at: testTime) }
        return ResearchSandboxClient(
            baseURL: baseURL, transport: SigningSandboxTransport(inner: transport),
            secretFile: TestSandboxSecret.file, now: { ResearchSandboxClient.testTime },
            proof: proof)
    }
}
