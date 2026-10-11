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

/// A folder for one test's secret file. The file is written the way the
/// launcher writes it: 64 hex characters, mode 0600.
private struct SecretFolder {
    static let secretText = String(repeating: "0123456789abcdef", count: 4)

    let folder: URL
    var file: URL { folder.appendingPathComponent("web-sandbox.secret") }

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
        let noFolder = folder.folder.appendingPathComponent("nothing/web-sandbox.secret")
        #expect(try ResearchSandboxSecret.contents(of: noFolder) == nil)
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
    /// written once each (`secret_file` in the script); this keeps them equal.
    @Test func theScriptWritesWhereTheClientReads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("Scripts/research_sandbox.sh"), encoding: .utf8)
        #expect(script.contains("secret_file=\"$HOME/" + ResearchSandboxSecret.relativePath + "\""))
    }

    @Test func theMessagesArePlain() {
        #expect(ResearchError.sandboxNotSigned(address: "127.0.0.1:9100").description
            == "the answer on 127.0.0.1:9100 is not signed by the SandSeek sandbox; "
            + "another program may be using the port")
        #expect(ResearchError.sandboxSecretUnusable("/x/secret is a symbolic link").description
            == "the sandbox's secret file cannot be used: /x/secret is a symbolic link")
    }
}

#if canImport(CryptoKit)

private func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// The documented formula, written out again here and not taken from the
/// code under test.
private func expectedSignature(key: Data, nonce: String, requestBody: Data,
                               status: Int, body: Data) -> String {
    let requestHash = hexString(SHA256.hash(data: requestBody))
    let head = "tuff-sandbox-v1\n" + nonce + "\n" + requestHash + "\n" + String(status) + "\n"
    let code = HMAC<SHA256>.authenticationCode(
        for: Data(head.utf8) + body, using: SymmetricKey(data: key))
    return hexString(code)
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

/// What the fake sandbox was asked.
private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(path: String, nonce: String?, body: Data)] = []

    func add(path: String, nonce: String?, body: Data) {
        lock.withLock { items.append((path, nonce, body)) }
    }

    var all: [(path: String, nonce: String?, body: Data)] { lock.withLock { items } }
}

/// A sandbox that answers /health, /v1/search and /v1/fetch, signing as the
/// real one does, or badly in the ways a program on its port might.
private struct FakeSandbox: ResearchHTTPTransport {
    enum Behaviour: Sendable {
        case honest
        case uppercaseSignature
        case wrongKey
        case unsigned
        case signedForAnotherBody
        case signedForAnotherStatus
        case signedForAnotherNonce
        case malformedSignature(String)
        case redirect
        /// A 408 for a body that did not arrive in full, signed over the empty
        /// body (the real server never had the whole one), with the given key.
        case requestTimeout(key: Data)
        /// An honest key, but the answer is signed over the empty body whatever
        /// was sent, with this status.
        case signedOverTheEmptyBody(status: Int)
    }

    let keys: KeyBox
    let behaviour: Behaviour
    let requests = Requests()

    init(key: Data, behaviour: Behaviour = .honest) {
        keys = KeyBox(key)
        self.behaviour = behaviour
    }

    static let timeoutBody = Data(
        #"{"error":{"code":"request_timeout","message":"timed out waiting for the request body"}}"#.utf8)

    private func answer(for url: URL) -> Data {
        switch url.lastPathComponent {
        case "health":
            return Data(#"{"status":"ok","passages":true,"raw":true,"signed":true}"#.utf8)
        case "search":
            return Data(#"{"results":[{"title":"A page","url":"https://example.com/a","snippet":"s"}]}"#.utf8)
        default:
            return Data(
                #"{"url":"https://example.com/a","title":"A page","text":"hello","offset":0,"total_chars":5}"#.utf8)
        }
    }

    /// An answer from a sandbox that was sent no nonce: unsigned.
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        requests.add(path: url.path, nonce: nil, body: body ?? Data())
        return ResearchHTTPResponse(status: 200, body: answer(for: url))
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        let nonce = headers["X-Sandbox-Nonce"] ?? ""
        let requestBody = body ?? Data()
        requests.add(path: url.path, nonce: headers["X-Sandbox-Nonce"], body: requestBody)
        let payload = answer(for: url)
        let honestKey = keys.value

        func sign(key: Data, nonce: String, requestBody: Data, status: Int) -> String {
            expectedSignature(key: key, nonce: nonce, requestBody: requestBody,
                              status: status, body: payload)
        }
        func signed(_ signature: String) -> ResearchHTTPResponse {
            ResearchHTTPResponse(status: 200, body: payload,
                                 headers: ["x-sandbox-signature": signature])
        }

        switch behaviour {
        case .honest:
            return signed(sign(key: honestKey, nonce: nonce, requestBody: requestBody, status: 200))
        case .uppercaseSignature:
            return signed(sign(key: honestKey, nonce: nonce, requestBody: requestBody, status: 200)
                .uppercased())
        case .wrongKey:
            return signed(sign(key: Data(repeating: 0x41, count: 32), nonce: nonce,
                               requestBody: requestBody, status: 200))
        case .unsigned:
            return ResearchHTTPResponse(status: 200, body: payload)
        case .signedForAnotherBody:
            return signed(sign(key: honestKey, nonce: nonce,
                               requestBody: Data(#"{"url":"https://other.example/"}"#.utf8), status: 200))
        case .signedForAnotherStatus:
            return signed(sign(key: honestKey, nonce: nonce, requestBody: requestBody, status: 201))
        case .signedForAnotherNonce:
            return signed(sign(key: honestKey, nonce: String(repeating: "0", count: 64),
                               requestBody: requestBody, status: 200))
        case .malformedSignature(let text):
            return signed(text)
        case .redirect:
            return ResearchHTTPResponse(status: 307, body: Data())
        case .signedOverTheEmptyBody(let status):
            let signature = expectedSignature(
                key: honestKey, nonce: nonce, requestBody: Data(), status: status, body: payload)
            return ResearchHTTPResponse(status: status, body: payload,
                                        headers: ["x-sandbox-signature": signature])
        case .requestTimeout(let key):
            let signature = expectedSignature(
                key: key, nonce: nonce, requestBody: Data(), status: 408, body: Self.timeoutBody)
            return ResearchHTTPResponse(status: 408, body: Self.timeoutBody,
                                        headers: ["x-sandbox-signature": signature])
        }
    }
}

@Suite struct ResearchSandboxSignedAnswerTests {
    private let baseURL = URL(string: "http://127.0.0.1:9100")!
    private let secret = Data(SecretFolder.secretText.utf8)
    private let notSigned = ResearchError.sandboxNotSigned(address: "127.0.0.1:9100")

    private func client(_ fake: FakeSandbox, file: URL?) -> ResearchSandboxClient {
        ResearchSandboxClient(baseURL: baseURL, transport: fake, secretFile: file)
    }

    private func everyCall(_ client: ResearchSandboxClient, expecting error: ResearchError) async {
        await #expect(throws: error) { try await client.checkHealth() }
        await #expect(throws: error) { _ = try await client.search(query: "q", maxResults: 3) }
        await #expect(throws: error) {
            _ = try await client.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        }
    }

    @Test func signedAnswersAreAcceptedWithAFreshNonceEachTime() async throws {
        let folder = try SecretFolder()
        let file = try folder.write()
        let fake = FakeSandbox(key: secret)
        let sandbox = client(fake, file: file)

        try await sandbox.checkHealth(requirePassages: true)
        let results = try await sandbox.search(query: "q", maxResults: 3)
        #expect(results.map(\.url) == ["https://example.com/a"])
        let slice = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        #expect(slice.text == "hello")

        let sent = fake.requests.all
        #expect(sent.map(\.path) == ["/health", "/v1/search", "/v1/fetch"])
        let nonces = sent.compactMap(\.nonce)
        #expect(nonces.count == 3)
        for nonce in nonces {
            #expect(nonce.count == 64)
            #expect(nonce.allSatisfy { $0.isHexDigit })
        }
        #expect(Set(nonces).count == 3)
    }

    @Test func aWrongSignatureIsRefusedBeforeTheBodyIsUsed() async throws {
        let file = try SecretFolder().write()
        await everyCall(client(FakeSandbox(key: secret, behaviour: .wrongKey), file: file),
                        expecting: notSigned)
    }

    @Test func aMissingSignatureIsRefusedWhenASecretExists() async throws {
        let file = try SecretFolder().write()
        await everyCall(client(FakeSandbox(key: secret, behaviour: .unsigned), file: file),
                        expecting: notSigned)
    }

    @Test func aSignatureMadeForAnotherRequestOrStatusOrNonceIsRefused() async throws {
        let file = try SecretFolder().write()
        for behaviour in [FakeSandbox.Behaviour.signedForAnotherBody, .signedForAnotherStatus,
                          .signedForAnotherNonce] {
            await everyCall(client(FakeSandbox(key: secret, behaviour: behaviour), file: file),
                            expecting: notSigned)
        }
    }

    @Test func aSignatureThatIsNot64HexCharactersIsRefused() async throws {
        let file = try SecretFolder().write()
        let good = String(repeating: "ab", count: 32)
        for text in ["", "abc", String(good.dropLast()), good + "a", String(repeating: "zz", count: 32),
                     " " + String(good.dropFirst())] {
            await everyCall(
                client(FakeSandbox(key: secret, behaviour: .malformedSignature(text)), file: file),
                expecting: notSigned)
        }
    }

    @Test func hexInUpperCaseIsStillTheSameSignature() async throws {
        let file = try SecretFolder().write()
        let sandbox = client(FakeSandbox(key: secret, behaviour: .uppercaseSignature), file: file)
        try await sandbox.checkHealth()
    }

    @Test func withoutASecretFileEverythingWorksAsBefore() async throws {
        let folder = try SecretFolder()
        // No file in an existing folder, and no file with no folder.
        for file in [Optional(folder.file), folder.folder.appendingPathComponent("a/b"), nil] {
            let fake = FakeSandbox(key: secret, behaviour: .unsigned)
            let sandbox = client(fake, file: file)
            try await sandbox.checkHealth(requirePassages: true)
            _ = try await sandbox.search(query: "q", maxResults: 3)
            _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
            #expect(fake.requests.all.count == 3)
            #expect(fake.requests.all.allSatisfy { $0.nonce == nil })
        }
    }

    @Test func theSecretIsReadAgainForEveryRequest() async throws {
        let folder = try SecretFolder()
        let fake = FakeSandbox(key: secret)
        let sandbox = client(fake, file: folder.file)

        try folder.write()
        try await sandbox.checkHealth()

        // The launcher started a new sandbox with a new secret.
        let newText = String(repeating: "fedcba9876543210", count: 4)
        try folder.write(newText)
        await #expect(throws: notSigned) { try await sandbox.checkHealth() }
        fake.keys.value = Data(newText.utf8)
        try await sandbox.checkHealth()

        // And the old sandbox answering now is not accepted any more.
        fake.keys.value = secret
        await #expect(throws: notSigned) { try await sandbox.checkHealth() }
    }

    @Test func aFileThatIsNotFitToUseStopsTheRequestBeforeItIsSent() async throws {
        let folder = try SecretFolder()
        let fake = FakeSandbox(key: secret)
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

    @Test func aRedirectIsStillTheRedirectErrorWithASecret() async throws {
        let file = try SecretFolder().write()
        await everyCall(client(FakeSandbox(key: secret, behaviour: .redirect), file: file),
                        expecting: .redirectRefused(status: 307))
    }

    /// The server answers 408 for a body that stopped short and signs it over
    /// the empty body; that is a tool failure, not an impostor.
    @Test func aTimeoutSignedOverTheEmptyBodyIsTheToolFailureNotAnImpostor() async throws {
        let file = try SecretFolder().write()
        let sandbox = client(FakeSandbox(key: secret, behaviour: .requestTimeout(key: secret)), file: file)
        let failure = ResearchToolFailure(
            message: "timed out waiting for the request body", status: 408)
        await #expect(throws: failure) { _ = try await sandbox.search(query: "q", maxResults: 3) }
        await #expect(throws: failure) {
            _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
        }
    }

    @Test func aTimeoutSignedWithAnotherKeyIsStillRefused() async throws {
        let file = try SecretFolder().write()
        let wrong = Data(repeating: 0x41, count: 32)
        await everyCall(
            client(FakeSandbox(key: secret, behaviour: .requestTimeout(key: wrong)), file: file),
            expecting: notSigned)
    }

    /// Only a 408 may be signed over the empty body; any other answer to a POST
    /// has to be signed over the body that was sent.
    @Test func anotherStatusSignedOverTheEmptyBodyIsRefused() async throws {
        let file = try SecretFolder().write()
        for status in [200, 400, 403, 413, 504] {
            let sandbox = client(
                FakeSandbox(key: secret, behaviour: .signedOverTheEmptyBody(status: status)), file: file)
            await #expect(throws: notSigned) { _ = try await sandbox.search(query: "q", maxResults: 3) }
            await #expect(throws: notSigned) {
                _ = try await sandbox.fetch(url: "https://example.com/a", offset: 0, maxCharacters: 100)
            }
        }
    }

    @Test func aTransportThatCannotSendHeadersFailsInsteadOfDroppingTheNonce() async throws {
        struct PlainTransport: ResearchHTTPTransport {
            func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
                ResearchHTTPResponse(status: 200, body: Data(#"{"passages":true}"#.utf8))
            }
        }
        let file = try SecretFolder().write()
        let sandbox = ResearchSandboxClient(baseURL: baseURL, transport: PlainTransport(), secretFile: file)
        await #expect(throws: ResearchError.self) { try await sandbox.checkHealth() }
        // Without a secret it is the plain request, as before.
        try await ResearchSandboxClient(baseURL: baseURL, transport: PlainTransport()).checkHealth()
    }

    @Test func theAddressInTheMessageIsTheConfiguredOne() async throws {
        let file = try SecretFolder().write()
        let elsewhere = ResearchSandboxClient(
            baseURL: URL(string: "http://127.0.0.1:9333")!,
            transport: FakeSandbox(key: secret, behaviour: .unsigned), secretFile: file)
        await #expect(throws: ResearchError.sandboxNotSigned(address: "127.0.0.1:9333")) {
            try await elsewhere.checkHealth()
        }
    }

    /// Values made by Python's hmac and hashlib for the same formula, so a
    /// mistake shared by the code and the helper above would still show.
    @Test func theSignatureMatchesValuesMadeOutsideSwift() {
        let nonce = String(repeating: "00112233445566778899aabbccddeeff", count: 2)
        let signing = ResearchSandboxSigning(key: secret, nonce: nonce)
        let known = ResearchSandboxSigning.decodeHex(
            "ac7201d0a1762a47cb156b87add5a35d0b6aab7c70e017e9c1106904458d4797")!
        let request = Data(#"{"url":"https://example.com/a"}"#.utf8)
        let answer = Data(#"{"final_url":"https://example.com/a","status":200}"#.utf8)
        #expect(signing.isValid(signature: known, requestBody: request, status: 200, responseBody: answer))
        #expect(!signing.isValid(signature: known, requestBody: Data(), status: 200, responseBody: answer))
        #expect(!signing.isValid(signature: known, requestBody: request, status: 201, responseBody: answer))
        #expect(!signing.isValid(signature: known, requestBody: request, status: 200, responseBody: Data()))
        let otherNonce = ResearchSandboxSigning(key: secret, nonce: String(nonce.reversed()))
        #expect(!otherNonce.isValid(signature: known, requestBody: request, status: 200, responseBody: answer))

        // A GET has no body: the hash of nothing.
        let health = ResearchSandboxSigning.decodeHex(
            "b1f0da2832ab579917f5499691b67bfe766e1cf253472c513e8953d4c559336d")!
        #expect(signing.isValid(signature: health, requestBody: Data(), status: 200,
                                responseBody: Data(#"{"status":"ok"}"#.utf8)))
    }
}

#endif
