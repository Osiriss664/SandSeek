import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Signed requests and signed answers.
//
// `Scripts/research_sandbox.sh start` makes a random secret, keeps it in a file
// only the user can read, and mounts the folder with that file read-only into
// the sandbox, which reads it once when it starts. Every request to the
// sandbox carries a fresh random nonce, the time in seconds, and
//
//   X-Sandbox-Auth: hex(HMAC-SHA256(secret, join("\n", [
//       "sandseek-sandbox-req-v1", method, path, nonce, time,
//       hex(SHA256(request body))])))
//
// and the sandbox refuses a request that is not signed correctly, that is
// more than a minute old, or whose nonce it has seen. Every answer must carry
//
//   X-Sandbox-Auth: hex(HMAC-SHA256(secret, join("\n", [
//       "sandseek-sandbox-resp-v1", method, path, nonce, status,
//       hex(SHA256(answer body))])))
//
// A program that only sits on the sandbox's port cannot make that, because the
// secret never crosses the port, and an old answer does not fit a new nonce.
// The check comes before the answer is read for anything else, and covers
// every status, so a 401 or 404 from a program that is not the sandbox is "not
// signed", not a tool failure. `Sandbox/test-vectors/signing.json` holds fixed
// examples that this code and the sandbox both reproduce.
//
// There is no unsigned mode. A missing secret file means the sandbox was not
// started (`stop` deletes it): the request is not sent. A file that exists but
// is not fit to use is an error too.

/// The secret the sandbox's launcher writes, and how it is read.
public enum ResearchSandboxSecret {
    /// Where the launcher writes the secret, from the home folder. The same
    /// path is `secret_file` in `Scripts/research_sandbox.sh`: change both
    /// together.
    public static let relativePath = "Library/Application Support/SandSeek/sandbox/secret"

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath, isDirectory: false)
    }

    /// The least a secret may hold, after the one newline that may end the file.
    public static let minimumBytes = 32
    /// More than this is not a secret the launcher wrote.
    static let maximumBytes = 4096

    /// (Not named `read`: inside this type that name would hide the C function
    /// `read` that the body calls.)
    ///
    /// The secret in `file`, read now and not remembered: the launcher makes a
    /// new one at every start. The key is the file's bytes without one
    /// trailing newline.
    ///
    /// Returns nil when there is no such file (the sandbox is not running;
    /// `required(at:)` turns that into an error). Throws
    /// `ResearchError.sandboxSecretUnusable` when there is one that is not
    /// fit to use: a symbolic link (it is not followed), not a regular file,
    /// not owned by the current user, readable or writable by group or others,
    /// unreadable, too long, or shorter than `minimumBytes`. The checks are
    /// made on the opened file, so the file cannot change between check and
    /// read.
    public static func contents(of file: URL) throws -> Data? {
        let path = file.path
        // O_NONBLOCK: opening a named pipe put at this path must not wait for a
        // writer. The file type is checked right after, before any read.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP { throw unusable("\(path) is a symbolic link") }
            throw unusable("\(path) cannot be opened (\(String(cString: strerror(code))))")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw unusable("\(path) cannot be examined (\(String(cString: strerror(errno))))")
        }
        let mode = mode_t(info.st_mode)
        guard (mode & 0o170000) == 0o100000 else {
            throw unusable("\(path) is not a regular file")
        }
        guard info.st_uid == geteuid() else {
            throw unusable("\(path) is not owned by you")
        }
        guard (mode & 0o077) == 0 else {
            throw unusable("\(path) can be read or changed by others (mode "
                + String(mode & 0o777, radix: 8) + "). Start the sandbox again to make a new "
                + "secret, or run chmod 600 on it")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw unusable("\(path) cannot be read (\(String(cString: strerror(errno))))")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maximumBytes {
                throw unusable("\(path) is longer than \(maximumBytes) bytes")
            }
        }
        if data.last == 0x0A { data.removeLast() }
        guard data.count >= minimumBytes else {
            throw unusable("\(path) holds fewer than \(minimumBytes) bytes. Start the sandbox "
                + "again to make a new secret")
        }
        return data
    }

    /// The secret in `file`, or `ResearchError.sandboxNotStarted` when there is
    /// no such file. This is what a request needs: there is no unsigned mode.
    public static func required(at file: URL) throws -> Data {
        guard let secret = try contents(of: file) else { throw ResearchError.sandboxNotStarted }
        return secret
    }

    private static func unusable(_ message: String) -> ResearchError {
        .sandboxSecretUnusable(message)
    }

    /// 32 random bytes as 64 lower-case hex characters, for one request. The
    /// system generator is seeded by the system and is secure.
    public static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return ResearchSandboxSigning.hex(bytes)
    }
}

/// One request's key, nonce and time: what to send, and how to check the
/// answer to it.
struct ResearchSandboxSigning: Sendable {
    static let requestLabel = "sandseek-sandbox-req-v1"
    static let responseLabel = "sandseek-sandbox-resp-v1"
    static let nonceHeader = "X-Sandbox-Nonce"
    static let timeHeader = "X-Sandbox-Time"
    static let authHeader = "X-Sandbox-Auth"
    /// The answer's header name in lower case, as `ResearchHTTPResponse.headers`
    /// has it.
    static let answerAuthHeader = "x-sandbox-auth"

    let key: Data
    /// The request's method and path as sent (`GET`, `/health`): both are signed.
    let method: String
    let path: String
    let nonce: String
    /// Unix time in seconds, as sent in `X-Sandbox-Time`.
    let time: String

    /// Reads the secret for one request. Throws `ResearchError.sandboxNotStarted`
    /// when there is no secret file, and fails closed where this platform
    /// cannot sign (CryptoKit is missing).
    static func begin(secretFile: URL, method: String, path: String, now: Date,
                      makeNonce: () -> String) throws -> ResearchSandboxSigning {
        let key = try ResearchSandboxSecret.required(at: secretFile)
        #if canImport(CryptoKit)
        return ResearchSandboxSigning(
            key: key, method: method, path: path, nonce: makeNonce(),
            time: String(Int(now.timeIntervalSince1970)))
        #else
        throw ResearchError.sandboxSecretUnusable(
            "this platform cannot sign requests to the sandbox; use a Mac")
        #endif
    }

    /// The three headers of the request, for `body`.
    func requestHeaders(body: Data) -> [String: String] {
        [Self.nonceHeader: nonce,
         Self.timeHeader: time,
         Self.authHeader: Self.requestAuth(key: key, method: method, path: path, nonce: nonce,
                                           time: time, body: body)]
    }

    /// Whether the answer is signed with this key for this request. A missing
    /// header, one that is not exactly 64 hex characters, and a wrong value are
    /// all false. The comparison takes the same time wherever the two values
    /// differ.
    func isValid(_ response: ResearchHTTPResponse) -> Bool {
        guard let header = response.headers[Self.answerAuthHeader],
              let received = Self.decodeHex(header) else { return false }
        return isValid(signature: received, status: response.status, responseBody: response.body)
    }

    func isValid(signature: Data, status: Int, responseBody: Data) -> Bool {
        #if canImport(CryptoKit)
        let message = Self.responseMessage(method: method, path: path, nonce: nonce,
                                           status: status, body: responseBody)
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature, authenticating: message, using: SymmetricKey(data: key))
        #else
        return false
        #endif
    }

    /// The text the request's HMAC is made over.
    static func requestMessage(method: String, path: String, nonce: String, time: String,
                               body: Data) -> Data {
        joined([requestLabel, method, path, nonce, time, sha256Hex(body)])
    }

    /// The text the answer's HMAC is made over.
    static func responseMessage(method: String, path: String, nonce: String, status: Int,
                                body: Data) -> Data {
        joined([responseLabel, method, path, nonce, String(status), sha256Hex(body)])
    }

    private static func joined(_ fields: [String]) -> Data {
        Data(fields.joined(separator: "\n").utf8)
    }

    /// `X-Sandbox-Auth` of a request: lower-case hex of the HMAC-SHA256.
    static func requestAuth(key: Data, method: String, path: String, nonce: String,
                            time: String, body: Data) -> String {
        authCode(key: key, message: requestMessage(
            method: method, path: path, nonce: nonce, time: time, body: body))
    }

    /// The `X-Sandbox-Auth` an answer to that request must carry.
    static func responseAuth(key: Data, method: String, path: String, nonce: String,
                             status: Int, body: Data) -> String {
        authCode(key: key, message: responseMessage(
            method: method, path: path, nonce: nonce, status: status, body: body))
    }

    /// Where CryptoKit is missing nothing can be signed; this is never sent,
    /// since `begin` throws first, and an answer is never valid.
    private static func authCode(key: Data, message: Data) -> String {
        #if canImport(CryptoKit)
        return hex(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        #else
        return ""
        #endif
    }

    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return hex(SHA256.hash(data: data))
        #else
        return ""
        #endif
    }

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef")
        var text = ""
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// The 32 bytes of exactly 64 hex characters (either case); nil for
    /// anything else.
    static func decodeHex(_ text: String) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]),
                  let low = nibble(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
