import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SandSeekCore

/// The checkout's folder, from this file's own path.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A folder for one test's secret file. The file is written the way the
/// launcher writes it: 64 hex characters, mode 0600.
private struct SecretFolder {
    static let secretText = String(repeating: "0123456789abcdef", count: 4)

    let folder: URL
    var file: URL { folder.appendingPathComponent("secret") }

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekSecret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    @discardableResult
    func write(_ text: String = SecretFolder.secretText, mode: Int = 0o600) throws -> URL {
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }
}

/// What `ResearchSandboxSecret.contents(of:)` says is wrong with a file; nil
/// when it reads fine.
private func problem(with file: URL) -> String? {
    do {
        _ = try ResearchSandboxSecret.contents(of: file)
        return nil
    } catch ResearchError.sandboxSecretUnusable(let message) {
        return message
    } catch {
        return "another kind of error: \(error)"
    }
}

@Suite struct ResearchSandboxSecretFileTests {
    private let secret = SecretFolder.secretText

    @Test func aMissingFileIsNoSecretAndNotAnError() throws {
        let folder = try SecretFolder()
        #expect(try ResearchSandboxSecret.contents(of: folder.file) == nil)
        let noFolder = folder.folder.appendingPathComponent("nothing/secret")
        #expect(try ResearchSandboxSecret.contents(of: noFolder) == nil)
    }

    /// A request needs a secret: no file means the sandbox was not started.
    @Test func requiringASecretThatIsMissingIsTheNotStartedError() throws {
        let folder = try SecretFolder()
        #expect(throws: ResearchError.sandboxNotStarted) {
            _ = try ResearchSandboxSecret.required(at: folder.file)
        }
        try folder.write()
        #expect(try ResearchSandboxSecret.required(at: folder.file) == Data(secret.utf8))
        try folder.write(mode: 0o644)
        #expect(throws: ResearchError.self) { _ = try ResearchSandboxSecret.required(at: folder.file) }
    }

    @Test func theKeyIsTheFilesBytesWithoutOneTrailingNewline() throws {
        let folder = try SecretFolder()
        try folder.write(secret)
        #expect(try ResearchSandboxSecret.contents(of: folder.file) == Data(secret.utf8))
        try folder.write(secret + "\n")
        #expect(try ResearchSandboxSecret.contents(of: folder.file) == Data(secret.utf8))
        try folder.write(secret + "\n\n")
        #expect(try ResearchSandboxSecret.contents(of: folder.file) == Data((secret + "\n").utf8))
        // Owner-read-only is as private as can be.
        try folder.write(secret, mode: 0o400)
        #expect(try ResearchSandboxSecret.contents(of: folder.file) == Data(secret.utf8))
    }

    @Test func fewerThan32BytesIsRefused() throws {
        let folder = try SecretFolder()
        let exactly32 = String(repeating: "k", count: 32)
        try folder.write(exactly32)
        #expect(problem(with: folder.file) == nil)
        try folder.write(exactly32 + "\n")
        #expect(problem(with: folder.file) == nil)
        let short = String(repeating: "k", count: 31)
        for text in ["", "\n", short, short + "\n"] {
            try folder.write(text)
            let message = try #require(problem(with: folder.file), "\(text.count) bytes were accepted")
            #expect(message.contains("fewer than 32 bytes"))
        }
    }

    @Test func aFileOthersCanReadOrChangeIsRefused() throws {
        let folder = try SecretFolder()
        for mode in [0o644, 0o640, 0o604, 0o660, 0o602, 0o666, 0o707] {
            try folder.write(secret, mode: mode)
            let message = try #require(problem(with: folder.file), "mode \(String(mode, radix: 8)) was accepted")
            #expect(message.contains("can be read or changed by others"))
        }
    }

    @Test func aSymbolicLinkIsNeverFollowed() throws {
        let folder = try SecretFolder()
        let real = folder.folder.appendingPathComponent("real.secret")
        try Data(secret.utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: folder.file.path, withDestinationPath: real.path)
        let message = try #require(problem(with: folder.file))
        #expect(message.contains("symbolic link"))
        // A link to nothing is a link, not a missing file.
        let dangling = folder.folder.appendingPathComponent("dangling.secret")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path, withDestinationPath: folder.folder.appendingPathComponent("gone").path)
        let danglingMessage = try #require(problem(with: dangling))
        #expect(danglingMessage.contains("symbolic link"))
    }

    @Test func aFolderOrAnOversizedFileIsRefused() throws {
        let folder = try SecretFolder()
        try FileManager.default.createDirectory(
            at: folder.file, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let folderMessage = try #require(problem(with: folder.file))
        #expect(folderMessage.contains("not a regular file"))

        let other = try SecretFolder()
        try other.write(String(repeating: "k", count: 5_000))
        let longMessage = try #require(problem(with: other.file))
        #expect(longMessage.contains("longer than"))
    }

    /// Opening a named pipe waits for a writer unless the open is non-blocking.
    @Test func aNamedPipeIsRefusedWithoutWaiting() throws {
        let folder = try SecretFolder()
        try #require(mkfifo(folder.file.path, 0o600) == 0)
        let message = try #require(problem(with: folder.file))
        #expect(message.contains("not a regular file"))
    }

    @Test func noMessageHoldsTheSecret() throws {
        let folder = try SecretFolder()
        let text = String(repeating: "s3cr3t", count: 5) + "!"
        for (content, mode) in [(text, 0o644), (String(text.prefix(20)), 0o600), (text + text, 0o666)] {
            try folder.write(content, mode: mode)
            if let message = problem(with: folder.file) {
                #expect(!message.contains("s3cr3t"))
            }
        }
    }

    @Test func aNonceIs64LowerCaseHexCharactersAndNeverRepeats() {
        let nonces = (0..<50).map { _ in ResearchSandboxSecret.randomNonce() }
        for nonce in nonces {
            #expect(nonce.count == 64)
            #expect(nonce.allSatisfy { $0.isHexDigit })
            #expect(nonce == nonce.lowercased())
        }
        #expect(Set(nonces).count == nonces.count)
    }

    @Test func aSignatureHeaderIsExactly64HexCharacters() {
        let valid = String(repeating: "ab", count: 32)
        #expect(ResearchSandboxSigning.decodeHex(valid)?.count == 32)
        #expect(ResearchSandboxSigning.decodeHex(valid.uppercased())?.count == 32)
        #expect(ResearchSandboxSigning.decodeHex(String(valid.dropLast())) == nil)
        #expect(ResearchSandboxSigning.decodeHex(valid + "a") == nil)
        #expect(ResearchSandboxSigning.decodeHex(String(repeating: "zz", count: 32)) == nil)
        #expect(ResearchSandboxSigning.decodeHex(" " + String(valid.dropFirst())) == nil)
        #expect(ResearchSandboxSigning.decodeHex("") == nil)
    }

    /// The app finds the file where the script writes it. The two paths are
    /// written once each (`secret_folder` and `secret_file` in the script);
    /// this keeps them equal.
    @Test func theScriptWritesWhereTheClientReads() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/research_sandbox.sh"),
            encoding: .utf8)
        let folder = (ResearchSandboxSecret.relativePath as NSString).deletingLastPathComponent
        #expect(script.contains("secret_folder=\"$HOME/" + folder + "\""))
        #expect(script.contains("secret_file=\"$secret_folder/secret\""))
        #expect(ResearchSandboxSecret.relativePath.hasSuffix("/secret"))
    }

    /// The old header and the old message format are gone from the app.
    @Test func theOldProtocolIsGone() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SandSeekCore/ResearchSandboxSigning.swift"),
            encoding: .utf8)
        #expect(!source.contains("tuff-sandbox-v1"))
        #expect(!source.contains("X-Sandbox-Signature"))
    }

    @Test func theMessagesArePlain() {
        #expect(ResearchError.sandboxNotSigned(address: "127.0.0.1:9100").description
            == "the answer on 127.0.0.1:9100 is not signed by the SandSeek sandbox; "
            + "another program may be using the port")
        #expect(ResearchError.sandboxSecretUnusable("/x/secret is a symbolic link").description
            == "the sandbox's secret file cannot be used: /x/secret is a symbolic link")
        #expect(ResearchError.sandboxNotStarted.description
            == "No sandbox secret: start the sandbox (Scripts/research_sandbox.sh start, or the "
            + "app's Start button).")
        #expect(ResearchError.sandboxWrongVersion.description.contains("Scripts/research_sandbox.sh build"))
    }
}


#if canImport(CryptoKit)

private func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func sha256Hex(_ data: Data) -> String {
    hexString(SHA256.hash(data: data))
}

private func hmacHex(key: Data, fields: [String]) -> String {
    let code = HMAC<SHA256>.authenticationCode(
        for: Data(fields.joined(separator: "\n").utf8), using: SymmetricKey(data: key))
    return hexString(code)
}

/// The documented formulas, written out again here and not taken from the
/// code under test.
private func expectedRequestAuth(key: Data, method: String, path: String, nonce: String,
                                 time: String, body: Data) -> String {
    hmacHex(key: key, fields: ["sandseek-sandbox-req-v1", method, path, nonce, time, sha256Hex(body)])
}

private func expectedResponseAuth(key: Data, method: String, path: String, nonce: String,
                                  status: Int, body: Data) -> String {
    hmacHex(key: key, fields: ["sandseek-sandbox-resp-v1", method, path, nonce, String(status),
                               sha256Hex(body)])
}

/// `Sandbox/test-vectors/signing.json`, which the sandbox's own tests reproduce too.
private struct SigningVectors: Decodable {
    struct Request: Decodable {
        let name: String
        let method: String
        let path: String
        let nonce: String
        let time: String
        let bodyUtf8: String
        let bodySha256: String
        let expectedAuth: String
    }

    struct Response: Decodable {
        let name: String
        let method: String
        let path: String
        let nonce: String
        let status: Int
        let bodyUtf8: String
        let bodySha256: String
        let expectedAuth: String
    }

    let secretUtf8: String
    let request: [Request]
    let response: [Response]

    static func load() throws -> SigningVectors {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "Sandbox/test-vectors/signing.json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SigningVectors.self, from: data)
    }
}

@Suite struct ResearchSandboxSigningVectorTests {
    @Test func theFileHasAtLeastThreeOfEachKind() throws {
        let vectors = try SigningVectors.load()
        #expect(vectors.request.count >= 3)
        #expect(vectors.response.count >= 3)
        #expect(Data(vectors.secretUtf8.utf8).count >= ResearchSandboxSecret.minimumBytes)
    }

    @Test func everyRequestVectorIsReproduced() throws {
        let vectors = try SigningVectors.load()
        let key = Data(vectors.secretUtf8.utf8)
        for vector in vectors.request {
            let body = Data(vector.bodyUtf8.utf8)
            #expect(ResearchSandboxSigning.sha256Hex(body) == vector.bodySha256, "\(vector.name)")
            #expect(ResearchSandboxSigning.requestAuth(
                key: key, method: vector.method, path: vector.path, nonce: vector.nonce,
                time: vector.time, body: body) == vector.expectedAuth, "\(vector.name)")
            // The headers the client sends.
            let signing = ResearchSandboxSigning(
                key: key, method: vector.method, path: vector.path, nonce: vector.nonce,
                time: vector.time)
            #expect(signing.requestHeaders(body: body) == [
                "X-Sandbox-Nonce": vector.nonce,
                "X-Sandbox-Time": vector.time,
                "X-Sandbox-Auth": vector.expectedAuth,
            ], "\(vector.name)")
        }
    }

    @Test func everyAnswerVectorIsReproducedAndAccepted() throws {
        let vectors = try SigningVectors.load()
        let key = Data(vectors.secretUtf8.utf8)
        for vector in vectors.response {
            let body = Data(vector.bodyUtf8.utf8)
            #expect(ResearchSandboxSigning.sha256Hex(body) == vector.bodySha256, "\(vector.name)")
            #expect(ResearchSandboxSigning.responseAuth(
                key: key, method: vector.method, path: vector.path, nonce: vector.nonce,
                status: vector.status, body: body) == vector.expectedAuth, "\(vector.name)")
            let signing = ResearchSandboxSigning(
                key: key, method: vector.method, path: vector.path, nonce: vector.nonce,
                time: "1786000000")
            let answer = ResearchHTTPResponse(
                status: vector.status, body: body,
                headers: ["x-sandbox-auth": vector.expectedAuth])
            #expect(signing.isValid(answer), "\(vector.name)")
            // Anything else the answer could be made for is not the same answer.
            let other = ResearchHTTPResponse(
                status: vector.status + 1, body: body, headers: answer.headers)
            #expect(!signing.isValid(other), "\(vector.name)")
            let otherBody = ResearchHTTPResponse(
                status: vector.status, body: body + Data(" ".utf8), headers: answer.headers)
            #expect(!signing.isValid(otherBody), "\(vector.name)")
        }
    }

    @Test func aVectorAnswerDoesNotFitAnotherMethodPathOrNonce() throws {
        let vectors = try SigningVectors.load()
        let key = Data(vectors.secretUtf8.utf8)
        let vector = try #require(vectors.response.first)
        let answer = ResearchHTTPResponse(
            status: vector.status, body: Data(vector.bodyUtf8.utf8),
            headers: ["x-sandbox-auth": vector.expectedAuth])
        for (method, path, nonce) in [
            (vector.method == "GET" ? "POST" : "GET", vector.path, vector.nonce),
            (vector.method, vector.path + "x", vector.nonce),
            (vector.method, vector.path, String(repeating: "1", count: 64)),
        ] {
            let signing = ResearchSandboxSigning(
                key: key, method: method, path: path, nonce: nonce, time: "1")
            #expect(!signing.isValid(answer))
        }
    }
}

/// The key the fake sandbox signs with, which a test can change.
private final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data

    init(_ key: Data) { self.key = key }

    var value: Data {
        get { lock.withLock { key } }
        set { lock.withLock { key = newValue } }
    }
}

/// A clock a test can move.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_786_000_000)

    var date: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// What the fake sandbox was asked, in order.
private final class Requests: @unchecked Sendable {
    struct Item {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func add(_ item: Item) { lock.withLock { items.append(item) } }

    var all: [Item] { lock.withLock { items } }
    var paths: [String] { all.map(\.path) }
}

/// A sandbox that answers /health, /v1/search and /v1/fetch, checking each
/// request's signature and signing as the real one does, or badly in the ways
/// a program on its port might.
private struct FakeSandbox: ResearchHTTPTransport {
    enum Behaviour: Sendable {
        case honest
        case uppercaseSignature
        case wrongKey
        /// No signature at all, with this status: a program that is not the sandbox.
        case unsigned(status: Int)
        case signedForAnotherPath
        case signedForAnotherMethod
        case signedForAnotherNonce
        case signedForAnotherStatus
        case malformedSignature(String)
        /// A correctly signed answer with this status and the usual body.
        case signedStatus(Int)
        case redirect
        /// A 408, as the real server answers a body that stopped short, with
        /// the signature over this body (empty or not).
        case requestTimeout(signedOver: Data)
    }

    let keys: KeyBox
    let behaviour: Behaviour
    var healthBody = Data(#"{"status":"ok","api":1,"passages":true,"pdf":false}"#.utf8)
    let requests = Requests()

    init(key: Data = TestSandboxSecret.key, behaviour: Behaviour = .honest,
         healthBody: Data? = nil) {
        keys = KeyBox(key)
        self.behaviour = behaviour
        if let healthBody { self.healthBody = healthBody }
    }

    static let timeoutBody = Data(
        #"{"error":{"code":"request_timeout","message":"timed out waiting for the request body"}}"#.utf8)

    private func answer(for url: URL) -> Data {
        switch url.lastPathComponent {
        case "health":
            return healthBody
        case "search":
            return Data(#"{"results":[{"title":"A page","url":"https://example.com/a","snippet":"s"}]}"#.utf8)
        default:
            return Data(
                #"{"url":"https://example.com/a","title":"A page","text":"hello","offset":0,"total_chars":5}"#.utf8)
        }
    }

    /// A request without the sandbox's headers: not signed, so not answered.
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        requests.add(Requests.Item(method: method, path: url.path, headers: [:], body: body ?? Data()))
        return ResearchHTTPResponse(status: 401, body: Data(
            #"{"error":{"code":"unauthorized","message":"the request is not signed correctly"}}"#.utf8))
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        let requestBody = body ?? Data()
        requests.add(Requests.Item(method: method, path: url.path, headers: headers, body: requestBody))
        let nonce = headers["X-Sandbox-Nonce"] ?? ""
        let honestKey = keys.value
        let path = url.path

        // The check the real server makes of a request.
        let requestOK = headers["X-Sandbox-Auth"] == expectedRequestAuth(
            key: honestKey, method: method, path: path, nonce: nonce,
            time: headers["X-Sandbox-Time"] ?? "", body: requestBody)
        var status = 200
        var payload = answer(for: url)
        if !requestOK {
            status = 401
            payload = Data(#"{"error":{"code":"unauthorized","message":"the request is not signed correctly"}}"#.utf8)
        }

        func sign(key: Data? = nil, method otherMethod: String? = nil, path otherPath: String? = nil,
                  nonce otherNonce: String? = nil, status otherStatus: Int? = nil,
                  body otherBody: Data? = nil) -> String {
            expectedResponseAuth(
                key: key ?? honestKey, method: otherMethod ?? method, path: otherPath ?? path,
                nonce: otherNonce ?? nonce, status: otherStatus ?? status, body: otherBody ?? payload)
        }
        func signed(_ signature: String, status otherStatus: Int? = nil,
                    body otherBody: Data? = nil) -> ResearchHTTPResponse {
            ResearchHTTPResponse(status: otherStatus ?? status, body: otherBody ?? payload,
                                 headers: ["x-sandbox-auth": signature])
        }

        switch behaviour {
        case .honest:
            return signed(sign())
        case .uppercaseSignature:
            return signed(sign().uppercased())
        case .wrongKey:
            return signed(sign(key: Data(repeating: 0x41, count: 32)))
        case .unsigned(let code):
            return ResearchHTTPResponse(status: code, body: payload)
        case .signedForAnotherPath:
            return signed(sign(path: path + "/other"))
        case .signedForAnotherMethod:
            return signed(sign(method: method == "GET" ? "POST" : "GET"))
        case .signedForAnotherNonce:
            return signed(sign(nonce: String(repeating: "0", count: 64)))
        case .signedForAnotherStatus:
            return signed(sign(status: status + 1))
        case .signedStatus(let code):
            return signed(sign(status: code), status: code)
        case .malformedSignature(let text):
            return signed(text)
        case .redirect:
            return ResearchHTTPResponse(status: 307, body: Data())
        case .requestTimeout(let over):
            return signed(sign(status: 408, body: over), status: 408, body: Self.timeoutBody)
        }
    }
}

private let sandboxURL = URL(string: "http://127.0.0.1:9100")!

private func client(_ fake: some ResearchHTTPTransport,
                    file: URL = TestSandboxSecret.file,
                    base: URL = sandboxURL,
                    clock: ClockBox = ClockBox(),
                    proved: Bool = true) -> ResearchSandboxClient {
    let proof = ResearchSandboxProof()
    if proved { proof.record(at: clock.date) }
    return ResearchSandboxClient(
        baseURL: base, transport: fake, secretFile: file, now: { clock.date }, proof: proof)
}

private func everyCall(_ client: ResearchSandboxClient, expecting error: ResearchError) async {
    await #expect(throws: error) { try await client.checkHealth() }
    await #expect(throws: error) { _ = try await client.search(query: "q", maxResults: 3) }
    await #expect(throws: error) {
        _ = try await client.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
    }
}

@Suite struct ResearchSandboxSignedRequestTests {
    @Test func everyRequestCarriesAFreshNonceTheTimeAndAValidSignature() async throws {
        let fake = FakeSandbox()
        let sandbox = client(fake)

        try await sandbox.checkHealth(requirePassages: true)
        let results = try await sandbox.search(query: "q", maxResults: 3)
        #expect(results.map(\.url) == ["https://example.com/a"])
        let slice = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        #expect(slice.text == "hello")

        let sent = fake.requests.all
        #expect(sent.map(\.path) == ["/health", "/v1/search", "/v1/fetch"])
        #expect(sent.map(\.method) == ["GET", "POST", "POST"])
        var nonces: Set<String> = []
        for item in sent {
            let nonce = try #require(item.headers["X-Sandbox-Nonce"])
            #expect(nonce.count == 64)
            #expect(nonce.allSatisfy { $0.isHexDigit })
            nonces.insert(nonce)
            #expect(item.headers["X-Sandbox-Time"] == "1786000000")
            #expect(item.headers["X-Sandbox-Auth"] == expectedRequestAuth(
                key: TestSandboxSecret.key, method: item.method, path: item.path, nonce: nonce,
                time: "1786000000", body: item.body))
            #expect(item.headers["X-Sandbox-Signature"] == nil)
        }
        #expect(nonces.count == 3)
        // The body that was signed is the body that was sent.
        let search = try #require(try ResearchJSON.decode(sent[1].body)["query"]?.stringValue)
        #expect(search == "q")
    }

    @Test func theTimeComesFromTheClock() async throws {
        let fake = FakeSandbox()
        let clock = ClockBox()
        clock.date = Date(timeIntervalSince1970: 1_786_000_042.9)
        try await client(fake, clock: clock).checkHealth()
        #expect(fake.requests.all.first?.headers["X-Sandbox-Time"] == "1786000042")
    }

    @Test func aBaseURLWithAPathSignsThePathThatIsSent() async throws {
        let fake = FakeSandbox()
        let sandbox = client(fake, base: URL(string: "http://127.0.0.1:9100/api")!)
        try await sandbox.checkHealth()
        _ = try await sandbox.search(query: "q", maxResults: 3)
        #expect(fake.requests.paths == ["/api/health", "/api/v1/search"])
        // The fake answers 401 to a request whose signature does not fit the
        // path it received, and the search above would have thrown.
    }

    @Test func withoutASecretFileNothingIsSent() async throws {
        let folder = try SecretFolder()
        let fake = FakeSandbox()
        // No file in an existing folder, and no file with no folder.
        for file in [folder.file, folder.folder.appendingPathComponent("a/b")] {
            await everyCall(client(fake, file: file), expecting: .sandboxNotStarted)
        }
        #expect(fake.requests.all.isEmpty)
        #expect(ResearchError.sandboxNotStarted.description.contains("start the sandbox"))
    }

    @Test func aFileThatIsNotFitToUseStopsTheRequestBeforeItIsSent() async throws {
        let folder = try SecretFolder()
        let fake = FakeSandbox()
        let sandbox = client(fake, file: folder.file)

        try folder.write(mode: 0o644)
        var failure: ResearchError?
        do { try await sandbox.checkHealth() } catch let error as ResearchError { failure = error }
        guard case .sandboxSecretUnusable(let message)? = failure else {
            Issue.record("expected an unusable secret, got \(String(describing: failure))")
            return
        }
        #expect(message.contains("can be read or changed by others"))
        #expect(!message.contains(SecretFolder.secretText))

        try folder.write("too short")
        await #expect(throws: ResearchError.self) { _ = try await sandbox.search(query: "q", maxResults: 3) }
        #expect(fake.requests.all.isEmpty)
    }

    @Test func theSecretIsReadAgainForEveryRequest() async throws {
        let folder = try SecretFolder()
        let fake = FakeSandbox()
        let sandbox = client(fake, file: folder.file)
        let notSigned = ResearchError.sandboxNotSigned(address: "127.0.0.1:9100")

        try folder.write()
        try await sandbox.checkHealth()

        // The launcher started a new sandbox with a new secret.
        let newText = String(repeating: "fedcba9876543210", count: 4)
        try folder.write(newText)
        // The fake still has the old key: it refuses the request (401, signed
        // with the old key), which the client cannot verify with the new one.
        await #expect(throws: notSigned) { try await sandbox.checkHealth() }
        fake.keys.value = Data(newText.utf8)
        try await sandbox.checkHealth()

        // And the old sandbox answering now is not accepted any more.
        fake.keys.value = TestSandboxSecret.key
        await #expect(throws: notSigned) { try await sandbox.checkHealth() }
    }

    @Test func aTransportThatCannotSendHeadersFailsInsteadOfSendingUnsigned() async throws {
        struct PlainTransport: ResearchHTTPTransport {
            func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
                ResearchHTTPResponse(status: 200, body: Data(#"{"status":"ok","api":1}"#.utf8))
            }
        }
        await #expect(throws: ResearchError.self) { try await client(PlainTransport()).checkHealth() }
    }
}

@Suite struct ResearchSandboxAnswerCheckTests {
    private let notSigned = ResearchError.sandboxNotSigned(address: "127.0.0.1:9100")

    @Test func aWrongSignatureIsRefusedBeforeTheBodyIsUsed() async {
        await everyCall(client(FakeSandbox(behaviour: .wrongKey)), expecting: notSigned)
    }

    @Test func aMissingSignatureIsRefusedWhateverTheStatus() async {
        // 401, 403 and 404 from a program that is not the sandbox are "not
        // signed", not a tool failure the model hears about.
        for status in [200, 401, 403, 404, 405, 413, 500, 502, 503] {
            await everyCall(client(FakeSandbox(behaviour: .unsigned(status: status))),
                            expecting: notSigned)
        }
    }

    @Test func aSignatureMadeForAnotherPathMethodNonceOrStatusIsRefused() async {
        for behaviour in [FakeSandbox.Behaviour.signedForAnotherPath, .signedForAnotherMethod,
                          .signedForAnotherNonce, .signedForAnotherStatus] {
            await everyCall(client(FakeSandbox(behaviour: behaviour)), expecting: notSigned)
        }
    }

    @Test func aSignatureThatIsNot64HexCharactersIsRefused() async {
        let good = String(repeating: "ab", count: 32)
        for text in ["", "abc", String(good.dropLast()), good + "a", String(repeating: "zz", count: 32),
                     " " + String(good.dropFirst())] {
            await everyCall(client(FakeSandbox(behaviour: .malformedSignature(text))),
                            expecting: notSigned)
        }
    }

    @Test func hexInUpperCaseIsStillTheSameSignature() async throws {
        try await client(FakeSandbox(behaviour: .uppercaseSignature)).checkHealth()
    }

    @Test func aRedirectIsStillTheRedirectError() async {
        await everyCall(client(FakeSandbox(behaviour: .redirect)),
                        expecting: .redirectRefused(status: 307))
    }

    @Test func aTimeoutIsAnOrdinarySignedAnswer() async throws {
        let fake = FakeSandbox(behaviour: .requestTimeout(signedOver: FakeSandbox.timeoutBody))
        let sandbox = client(fake)
        let failure = ResearchToolFailure(
            message: "timed out waiting for the request body", status: 408)
        await #expect(throws: failure) { _ = try await sandbox.search(query: "q", maxResults: 3) }
        await #expect(throws: failure) {
            _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        }
    }

    @Test func aTimeoutSignedOverAnEmptyBodyIsNoLongerAccepted() async {
        let sandbox = client(FakeSandbox(behaviour: .requestTimeout(signedOver: Data())))
        await everyCall(sandbox, expecting: notSigned)
    }

    @Test func theAddressInTheMessageIsTheConfiguredOne() async {
        let elsewhere = client(FakeSandbox(behaviour: .unsigned(status: 200)),
                               base: URL(string: "http://127.0.0.1:9333")!)
        await #expect(throws: ResearchError.sandboxNotSigned(address: "127.0.0.1:9333")) {
            try await elsewhere.checkHealth()
        }
    }
}

@Suite struct ResearchSandboxHealthTests {
    private func health(_ json: String) -> FakeSandbox {
        FakeSandbox(healthBody: Data(json.utf8))
    }

    @Test func aSignedOkWithApi1Passes() async throws {
        try await client(health(#"{"status":"ok","api":1,"passages":true,"pdf":true}"#))
            .checkHealth(requirePassages: true)
    }

    @Test func anotherApiVersionOrNoneIsADifferentSandbox() async {
        for json in [#"{"status":"ok","api":2,"passages":true}"#,
                     #"{"status":"ok","api":0,"passages":true}"#,
                     #"{"status":"ok","passages":true,"raw":true,"signed":true}"#,
                     #"{"status":"ok","api":"1","passages":true}"#] {
            await #expect(throws: ResearchError.sandboxWrongVersion) {
                try await client(health(json)).checkHealth()
            }
        }
    }

    @Test func aStatusThatIsNotOkOrNotJSONIsRefused() async {
        for json in [#"{"status":"starting","api":1}"#, #"{"api":1}"#, "[]", "not json", ""] {
            await #expect(throws: ResearchError.self) { try await client(health(json)).checkHealth() }
        }
    }

    @Test func passagesAreRequiredOnlyWhenAsked() async throws {
        let old = client(health(#"{"status":"ok","api":1,"passages":false}"#))
        try await old.checkHealth()
        await #expect(throws: ResearchError.sandboxCannotRankPassages) {
            try await old.checkHealth(requirePassages: true)
        }
    }

    @Test func aSignedAnswerThatIsNot200IsUnavailable() async {
        // Genuine, but not healthy.
        await #expect(throws: ResearchError.sandboxUnavailable("health check answered HTTP 503")) {
            try await client(FakeSandbox(behaviour: .signedStatus(503))).checkHealth()
        }
    }

    @Test func aSignedFailureStatusIsAToolFailureNotAnImpostor() async {
        let sandbox = client(FakeSandbox(behaviour: .signedStatus(404)))
        await #expect(throws: ResearchToolFailure.self) {
            _ = try await sandbox.search(query: "q", maxResults: 3)
        }
    }
}

@Suite struct ResearchSandboxIdentityTests {
    @Test func aSearchAfterAGapStartsWithASignedHealthCheck() async throws {
        let fake = FakeSandbox()
        let sandbox = client(fake, proved: false)

        _ = try await sandbox.search(query: "q", maxResults: 3)
        #expect(fake.requests.paths == ["/health", "/v1/search"])
    }

    @Test func aReadAfterAGapStartsWithASignedHealthCheck() async throws {
        let fake = FakeSandbox()
        let sandbox = client(fake, proved: false)

        _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        #expect(fake.requests.paths == ["/health", "/v1/fetch"])
    }

    @Test func requestsRightAfterAHealthCheckDoNotRepeatIt() async throws {
        let fake = FakeSandbox()
        let clock = ClockBox()
        let sandbox = client(fake, clock: clock, proved: false)

        try await sandbox.checkHealth()
        clock.date = clock.date.addingTimeInterval(4)
        _ = try await sandbox.search(query: "q", maxResults: 3)
        _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        #expect(fake.requests.paths == ["/health", "/v1/search", "/v1/fetch"])
    }

    @Test func aPauseOfMoreThanFiveSecondsAsksAgain() async throws {
        let fake = FakeSandbox()
        let clock = ClockBox()
        let sandbox = client(fake, clock: clock, proved: false)

        try await sandbox.checkHealth()
        clock.date = clock.date.addingTimeInterval(5)
        _ = try await sandbox.search(query: "q", maxResults: 3)
        clock.date = clock.date.addingTimeInterval(5.5)
        _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        clock.date = clock.date.addingTimeInterval(1)
        _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        // At exactly 5 s the proof still counts; at 10.5 s it does not, and the
        // check that then passes vouches for the read a second later.
        #expect(fake.requests.paths == ["/health", "/v1/search", "/health", "/v1/fetch", "/v1/fetch"])
    }

    @Test func aTimeThatWentBackwardsIsNoProof() async throws {
        let fake = FakeSandbox()
        let clock = ClockBox()
        let sandbox = client(fake, clock: clock, proved: false)

        try await sandbox.checkHealth()
        clock.date = clock.date.addingTimeInterval(-60)
        _ = try await sandbox.search(query: "q", maxResults: 3)
        #expect(fake.requests.paths == ["/health", "/health", "/v1/search"])
    }

    @Test func copiesOfTheClientShareTheProof() async throws {
        let fake = FakeSandbox()
        let sandbox = client(fake, proved: false)
        let copy = sandbox

        try await sandbox.checkHealth()
        _ = try await copy.search(query: "q", maxResults: 3)
        #expect(fake.requests.paths == ["/health", "/v1/search"])
    }

    @Test func aHealthCheckThatFailsStopsTheRequestBeforeItIsSent() async {
        let notSigned = ResearchError.sandboxNotSigned(address: "127.0.0.1:9100")
        let fake = FakeSandbox(behaviour: .unsigned(status: 200))
        let sandbox = client(fake, proved: false)

        await #expect(throws: notSigned) { _ = try await sandbox.search(query: "q", maxResults: 3) }
        await #expect(throws: notSigned) {
            _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        }
        // Only the health checks went out: no search and no page request.
        #expect(fake.requests.paths == ["/health", "/health"])
    }

    @Test func aDifferentVersionStopsTheRequestToo() async {
        let fake = FakeSandbox(healthBody: Data(#"{"status":"ok","api":2}"#.utf8))
        let sandbox = client(fake, proved: false)
        await #expect(throws: ResearchError.sandboxWrongVersion) {
            _ = try await sandbox.search(query: "q", maxResults: 3)
        }
        #expect(fake.requests.paths == ["/health"])
    }

    @Test func aBadAnswerTakesTheProofAway() async throws {
        let fake = FakeSandbox()
        let sandbox = client(fake, proved: true)
        _ = try await sandbox.search(query: "q", maxResults: 3)
        #expect(fake.requests.paths == ["/v1/search"])

        // The secret changed under it: the next answer cannot be verified.
        fake.keys.value = Data(repeating: 0x43, count: 40)
        await #expect(throws: ResearchError.self) { _ = try await sandbox.search(query: "q", maxResults: 3) }
        fake.keys.value = TestSandboxSecret.key
        _ = try await sandbox.search(query: "q", maxResults: 3)
        #expect(fake.requests.paths == ["/v1/search", "/v1/search", "/health", "/v1/search"])
    }
}

#else

/// Without CryptoKit nothing can be signed, so every request is refused
/// before it is sent.
@Suite struct ResearchSandboxWithoutCryptoKitTests {
    private struct CountingTransport: ResearchHTTPTransport {
        func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
            ResearchHTTPResponse(status: 200, body: Data(#"{"status":"ok","api":1}"#.utf8))
        }
    }

    @Test func everyRequestFailsClosed() async {
        let sandbox = ResearchSandboxClient(
            baseURL: URL(string: "http://127.0.0.1:9100")!, transport: CountingTransport(),
            secretFile: TestSandboxSecret.file)
        await #expect(throws: ResearchError.self) { try await sandbox.checkHealth() }
        await #expect(throws: ResearchError.self) { _ = try await sandbox.search(query: "q", maxResults: 3) }
    }
}

#endif
