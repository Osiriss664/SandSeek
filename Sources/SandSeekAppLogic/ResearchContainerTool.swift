import Foundation
import SandSeekCore

/// A version such as `1.5.0`, as `container --version` prints it.
public struct ResearchContainerVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (left: ResearchContainerVersion, right: ResearchContainerVersion) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }

    /// The first `1.5` or `1.5.0` in the output of `container --version`.
    public static func parse(_ output: String) -> ResearchContainerVersion? {
        guard let match = output.firstMatch(of: #/(\d+)\.(\d+)(?:\.(\d+))?/#),
              let major = Int(match.1), let minor = Int(match.2) else { return nil }
        let patch = match.3.flatMap { Int($0) } ?? 0
        return ResearchContainerVersion(major: major, minor: minor, patch: patch)
    }
}

/// The file or folder that stopped the ownership check: it is not owned by
/// root, or group or others can write to it, or (for the file) it is not an
/// executable regular file.
public struct ResearchUntrustedPath: Equatable, Sendable {
    public let path: String
    /// True for a folder above the tool, false for the tool file itself.
    public let isFolder: Bool

    public init(path: String, isFolder: Bool) {
        self.path = path
        self.isFolder = isFolder
    }
}

/// Why SandSeek will not run the `container` tool, in plain words. The text
/// is what the sandbox card shows.
public enum ResearchContainerError: Error, Equatable, CustomStringConvertible, Sendable {
    case notInstalled
    /// Installed, but the file or a folder above it could be changed by the
    /// user, their group or anyone else but root. `ResearchUntrustedPath` says
    /// which one.
    case notTrusted(ResearchUntrustedPath)
    /// The code signature is missing, broken, or not Apple's. `reason` is a
    /// short phrase or the tail of what `codesign` said.
    case notSigned(reason: String)
    case versionUnreadable(detail: String)
    case tooOld(found: String, minimum: String)

    public var description: String {
        let path = ResearchContainerTool.installedPath
        switch self {
        case .notInstalled:
            return "Apple container is not installed at \(path). Install it with Apple's "
                + "installer from https://github.com/apple/container and try again."
        case .notTrusted(let untrusted) where untrusted.isFolder:
            return "Apple container is at \(path), but the folder \(untrusted.path) above it can be "
                + "changed by you or another user, so SandSeek will not run it. Apple's installer "
                + "does not change this folder. To let SandSeek trust it, make it belong to root: "
                + "sudo chown root:wheel \(untrusted.path) && sudo chmod 755 \(untrusted.path) "
                + "(this affects an Intel Homebrew installed in /usr/local)."
        case .notTrusted(let untrusted):
            return "Apple container is at \(path), but the file \(untrusted.path) can be changed "
                + "by you or another user (it must belong to root alone), so SandSeek will not run it. "
                + "Reinstall it with Apple's installer (https://github.com/apple/container), "
                + "which makes it belong to root alone."
        case .notSigned(let reason):
            let detail = reason.isEmpty ? "" : " (\(reason))"
            return "The program at \(path) is not signed by Apple\(detail), so SandSeek will not "
                + "run it. Install Apple container from https://github.com/apple/container."
        case .versionUnreadable(let detail):
            let tail = detail.isEmpty ? "" : " (\(detail))"
            return "SandSeek could not read the version of Apple container\(tail)."
        case .tooOld(let found, let minimum):
            return "Apple container \(found) is installed, but SandSeek needs \(minimum) or newer. "
                + "Update it from https://github.com/apple/container."
        }
    }
}

/// Apple's `container` command-line tool. SandSeek runs only the file at
/// `/usr/local/bin/container`, where Apple's installer puts it, never a copy
/// found through PATH, and checks that file before the first command of a
/// session: it and every folder above it belong to root and cannot be
/// changed by anyone else, its code signature chains to Apple's and names
/// Apple's team, and its version is recent enough.
///
/// The check and the first command are separate steps, so a program that
/// could replace the file in between would still win; that takes root, which
/// can do far more anyway. The script (`Scripts/research_sandbox.sh`) makes
/// the same checks before it runs `container` itself.
public struct ResearchContainerTool: Sendable {
    public static let installedPath = "/usr/local/bin/container"
    public static let minimumVersion = ResearchContainerVersion(major: 1, minor: 5, patch: 0)
    /// The team of "Developer ID Application: Apple Inc. - Containerization",
    /// which signs Apple's release.
    public static let appleTeamIdentifier = "UPBK2H6LZM"
    /// What the signature must satisfy: it chains to Apple's certificate
    /// authority and the signing certificate carries Apple's team, so a
    /// certificate someone made themselves does not pass. The script uses the
    /// same text.
    public static let signatureRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(appleTeamIdentifier)\""

    private let runner: any ResearchProcessRunning
    public let path: String
    private let environment: [String: String]
    /// Nil when the file at the path is trusted, otherwise what failed.
    private let untrustedPath: @Sendable (String) -> ResearchUntrustedPath?
    /// Whether an executable file is there at all, trusted or not: it tells
    /// "not installed" from "installed, but not run because someone besides
    /// root could replace it".
    private let fileExists: @Sendable (String) -> Bool
    private let identity: @Sendable (String) -> String?

    public init(runner: any ResearchProcessRunning = FoundationProcessRunner(),
                path: String = ResearchContainerTool.installedPath,
                environment: [String: String] = ResearchCommandEnvironment.environment(),
                untrustedPath: @escaping @Sendable (String) -> ResearchUntrustedPath? =
                    ResearchContainerTool.firstUntrustedPath,
                fileExists: @escaping @Sendable (String) -> Bool = {
                    FileManager.default.isExecutableFile(atPath: $0)
                },
                identity: @escaping @Sendable (String) -> String? = ResearchContainerTool.fileIdentity) {
        self.runner = runner
        self.path = path
        self.environment = environment
        self.untrustedPath = untrustedPath
        self.fileExists = fileExists
        self.identity = identity
    }

    /// The tool as a file URL, for the process runner.
    public var url: URL { URL(fileURLWithPath: path) }

    /// Tells whether the tool file is still the one that was checked: the
    /// same file number, size and change time. Nil if it cannot be read.
    public func currentIdentity() -> String? { identity(path) }

    /// Nil for an executable regular file that only root can change: the real
    /// file and every folder above it belong to root and cannot be written by
    /// group or others. Both the path as given and the file it resolves to are
    /// checked, so a link placed in a folder the user can write does not help.
    /// Otherwise the first file or folder that fails.
    @Sendable public static func firstUntrustedPath(_ path: String) -> ResearchUntrustedPath? {
        let given = URL(fileURLWithPath: path)
        let resolved = given.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: path),
              let kind = try? FileManager.default.attributesOfItem(atPath: resolved.path)[.type]
                as? FileAttributeType,
              kind == .typeRegular
        else { return ResearchUntrustedPath(path: resolved.path, isFolder: false) }
        return firstOpenPath(from: given) ?? firstOpenPath(from: resolved)
    }

    /// Whether the file is trusted; see `firstUntrustedPath`.
    @Sendable public static func isTrustedFile(_ path: String) -> Bool {
        firstUntrustedPath(path) == nil
    }

    /// `start` and each folder above it, up to `/`: the first that is not
    /// owned by root or can be written by group or others.
    private static func firstOpenPath(from start: URL) -> ResearchUntrustedPath? {
        var url = start
        while true {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  permissions & 0o022 == 0
            else { return ResearchUntrustedPath(path: url.path, isFolder: url.path != start.path) }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path || url.path == "/" { return nil }
            url = parent
        }
    }

    /// Which file is at `path`: its device, file number, size and times of
    /// last modification and last change (the change time cannot be set
    /// back). Nil if it cannot be read.
    @Sendable public static func fileIdentity(_ path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(resolved, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return "\(info.st_dev)-\(info.st_ino)-\(info.st_size)"
            + "-\(modified.tv_sec).\(modified.tv_nsec)-\(changed.tv_sec).\(changed.tv_nsec)"
    }

    /// Checks that the tool is installed, belongs to root alone, is signed by
    /// Apple and is recent enough. Every command has a time limit.
    @discardableResult
    public func verify() async throws -> ResearchContainerVersion {
        if let untrusted = untrustedPath(path) {
            // Installed but changeable by someone else is a different problem
            // from not installed, and installing again is not the fix.
            throw fileExists(path)
                ? ResearchContainerError.notTrusted(untrusted) : ResearchContainerError.notInstalled
        }
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        let signature = await run(codesign, [
            "--verify", "--strict", "-R=\(Self.signatureRequirement)", path,
        ], timeout: 30)
        guard signature.status == 0, !signature.timedOut else {
            throw ResearchContainerError.notSigned(reason: Self.reason(signature))
        }
        // The requirement above already pins the team; this reads it back, so
        // a tool that is ad hoc signed or names another team is refused even
        // if the requirement check were ever to let it by.
        let details = await run(codesign, ["-dv", "--verbose=2", path], timeout: 30)
        let lines = details.output.split(whereSeparator: \.isNewline).map(String.init)
        guard details.status == 0, !details.timedOut, !lines.contains("Signature=adhoc") else {
            throw ResearchContainerError.notSigned(reason: "it is not signed by a developer")
        }
        let team = lines.first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
        guard team == Self.appleTeamIdentifier else {
            throw ResearchContainerError.notSigned(reason: "the signer is not Apple's")
        }
        let versionReply = await run(url, ["--version"], timeout: 15)
        guard versionReply.status == 0, !versionReply.timedOut,
              let version = ResearchContainerVersion.parse(versionReply.output) else {
            throw ResearchContainerError.versionUnreadable(detail: Self.reason(versionReply))
        }
        guard version >= Self.minimumVersion else {
            throw ResearchContainerError.tooOld(
                found: version.description, minimum: Self.minimumVersion.description)
        }
        return version
    }

    /// Runs one command. A command that cannot even start (the file is gone,
    /// or not allowed to run) counts as a failed one, with the system's reason
    /// as its output, so every failure ends as one of `ResearchContainerError`.
    private func run(_ executable: URL, _ arguments: [String],
                     timeout: TimeInterval) async -> ResearchProcessResult {
        do {
            return try await runner.run(executable: executable, arguments: arguments,
                                        environment: environment, timeout: timeout)
        } catch {
            return ResearchProcessResult(status: -1, output: error.localizedDescription)
        }
    }

    /// A short, clean phrase for an error message: why it timed out, or the
    /// last two lines the command printed.
    private static func reason(_ result: ResearchProcessResult) -> String {
        if result.timedOut { return "it did not answer in time" }
        return ResearchText.terminalSafe(result.tail(2))
            .replacingOccurrences(of: "\n", with: "; ")
    }
}
