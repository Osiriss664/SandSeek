import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// What `Scripts/research_sandbox.sh start` records next to the secret, in
// `~/Library/Application Support/SandSeek/sandbox`:
//
//   port      the port on 127.0.0.1 it picked (free at each start): digits only
//   vm-name   the name of the VM it started: sandseek-sandbox- and 8 hex digits
//   lock      the lock, held for as long as the sandbox runs (see
//             `ResearchSandboxLock`)
//
// The app, the `sandseek` command and the scripts all find the sandbox through
// these files. The port and the name are read as strictly as the secret: a
// plain file of yours that nobody else can read or write, with nothing in it
// but the value. Anything else is "nothing recorded" or an error, never a
// guess.

/// Why a recorded file cannot be used. The message names the file and never
/// holds the secret.
public struct ResearchSandboxFileError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
}

public enum ResearchSandboxFiles {
    public static let portFileName = "port"
    public static let nameFileName = "vm-name"
    public static let lockFileName = "lock"
    /// The port used only when no port was recorded (the sandbox is not
    /// running, or was started by hand on its old port).
    public static let fallbackPort = 9100
    /// The lowest port `start` records.
    public static let lowestPort = 1024
    /// The first part of every VM's name.
    public static let namePrefix = "sandseek-sandbox"

    /// The folder that holds the secret. The same path is `secret_folder` in
    /// `Scripts/research_sandbox.sh`: change both together.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SandSeek/sandbox", isDirectory: true)
    }

    /// The folder a secret file is in: the other files are beside it.
    public static func folder(ofSecretFile secretFile: URL) -> URL {
        secretFile.deletingLastPathComponent()
    }

    public static func portFile(in folder: URL) -> URL {
        folder.appendingPathComponent(portFileName, isDirectory: false)
    }

    public static func nameFile(in folder: URL) -> URL {
        folder.appendingPathComponent(nameFileName, isDirectory: false)
    }

    public static func lockFile(in folder: URL) -> URL {
        folder.appendingPathComponent(lockFileName, isDirectory: false)
    }

    /// A port from the file's text: digits only (one line break may end it),
    /// 1024 to 65535. Nil for anything else.
    public static func parsePort(_ text: String) -> Int? {
        var digits = Substring(text)
        if digits.hasSuffix("\n") { digits = digits.dropLast() }
        guard (4...5).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
              let port = Int(digits), (lowestPort...65_535).contains(port) else { return nil }
        return port
    }

    /// A VM name from the file's text: `sandseek-sandbox-` and 8 lower-case hex
    /// digits (one line break may end it). Nil for anything else.
    public static func parseName(_ text: String) -> String? {
        var name = Substring(text)
        if name.hasSuffix("\n") { name = name.dropLast() }
        guard name.hasPrefix(namePrefix + "-") else { return nil }
        let suffix = name.dropFirst(namePrefix.count + 1)
        guard suffix.count == 8,
              suffix.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) })
        else { return nil }
        return String(name)
    }

    /// The recorded port: nil when there is no port file (nothing was started),
    /// an error when there is one that is not fit to use (not a plain file of
    /// yours, readable or writable by others, or not a port).
    public static func readPort(in folder: URL) throws -> Int? {
        let file = portFile(in: folder)
        guard let text = try privateText(at: file) else { return nil }
        guard let port = parsePort(text) else {
            throw ResearchSandboxFileError(
                message: "\(file.path) does not hold a port number (1024 to 65535). "
                    + "Start the sandbox again")
        }
        return port
    }

    /// The recorded VM name, with the same rules as `readPort`.
    public static func readName(in folder: URL) throws -> String? {
        let file = nameFile(in: folder)
        guard let text = try privateText(at: file) else { return nil }
        guard let name = parseName(text) else {
            throw ResearchSandboxFileError(
                message: "\(file.path) does not hold a sandbox name. Start the sandbox again")
        }
        return name
    }

    /// `http://127.0.0.1:<port>`.
    public static func url(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Where the sandbox is: `SANDSEEK_SANDBOX_PORT` when `environment` has it
    /// (for tests; digits only, 1024 to 65535 like a recorded port), else the
    /// recorded port, else `fallbackPort`. A port file that cannot be used counts as none.
    public static func sandboxURL(folder: URL, environment: [String: String]) -> URL {
        if let fixed = environment["SANDSEEK_SANDBOX_PORT"], !fixed.isEmpty,
           fixed.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
           let port = Int(fixed), (lowestPort...65_535).contains(port) {
            return url(port: port)
        }
        let recorded = try? readPort(in: folder)
        return url(port: recorded ?? fallbackPort)
    }

    /// The text of a small file, or nil when there is no such file. The file is
    /// opened without following a symbolic link and must be a regular file
    /// that is yours with mode 0600 exactly, and at most 64 bytes long; the
    /// checks are made on the opened file. Throws `ResearchSandboxFileError`
    /// otherwise.
    static func privateText(at file: URL) throws -> String? {
        let path = file.path
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
        guard (mode & 0o170000) == 0o100000 else { throw unusable("\(path) is not a regular file") }
        guard info.st_uid == geteuid() else { throw unusable("\(path) is not owned by you") }
        guard (mode & 0o777) == 0o600 else {
            throw unusable("\(path) has mode " + String(mode & 0o777, radix: 8)
                + ", not 600. Start the sandbox again")
        }

        let limit = 64
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 128)
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
            if data.count > limit { throw unusable("\(path) is longer than \(limit) bytes") }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func unusable(_ message: String) -> ResearchSandboxFileError {
        ResearchSandboxFileError(message: message)
    }
}
