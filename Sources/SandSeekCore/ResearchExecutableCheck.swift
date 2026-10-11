import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// "Is this the program the person chose, and can nobody else have swapped it?"
//
// Before SandSeek starts a server it looks at the program file and at every
// folder from `/` down to it. A program that other users can write to, or
// that sits in a folder they can rename, could be replaced by something
// else. Programs of this Mac's own user are trusted (see SECURITY.md); this
// closes the doors for everyone else. The check cannot close the gap between
// looking and starting (macOS has no way to start a program from an open
// file), and it does not try to: it looks at who may write, not at a
// checksum. The rule itself is pure (`evaluate`), so it is tested with made-up
// file facts; the part that reads real files comes after it.

/// What the check needs to know about one file or folder.
public struct ResearchFileFacts: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case regular, directory, symlink, other }

    public var path: String
    public var kind: Kind
    public var uid: UInt32
    public var gid: UInt32
    /// The permission bits including the sticky bit (`0o1777`).
    public var mode: UInt32
    /// Whether the current user may run it (`access(X_OK)`).
    public var isExecutable: Bool
    /// macOS marked the file as downloaded and nobody approved it yet
    /// (`com.apple.quarantine` without the approved bit).
    public var isQuarantined: Bool

    public init(path: String, kind: Kind, uid: UInt32, gid: UInt32, mode: UInt32,
                isExecutable: Bool = true, isQuarantined: Bool = false) {
        self.path = path
        self.kind = kind
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.isExecutable = isExecutable
        self.isQuarantined = isQuarantined
    }
}

public enum ResearchExecutableCheck {
    /// The group macOS gives to administrators. `/Applications` (root) and the
    /// Homebrew folders (you) have this group and mode 775, so that group may
    /// write there. Its members can become root with `sudo` anyway.
    static let adminGroup: UInt32 = 80

    /// Why the program may not be started, or nil. `file` is the resolved
    /// program, `ancestors` are the folders above it from `/` down, and `uid`
    /// is the current user.
    public static func evaluate(file: ResearchFileFacts, ancestors: [ResearchFileFacts],
                                uid: UInt32) -> ResearchLaunchProblem? {
        guard file.kind == .regular else {
            return ResearchLaunchProblem("\(file.path) is not a regular program file.")
        }
        guard file.isExecutable else {
            return ResearchLaunchProblem("\(file.path) cannot be run by you.")
        }
        guard file.uid == uid || file.uid == 0 else {
            return ResearchLaunchProblem("\(file.path) belongs to another user.")
        }
        guard file.mode & 0o022 == 0 else {
            return ResearchLaunchProblem("\(file.path) can be changed by other users.")
        }
        for folder in ancestors {
            guard folder.kind == .directory else {
                return ResearchLaunchProblem("\(folder.path) is not a folder.")
            }
            guard folder.uid == uid || folder.uid == 0 else {
                return ResearchLaunchProblem("The folder \(folder.path) belongs to another user.")
            }
            // A sticky world-writable folder (/tmp) lets nobody rename what is
            // not theirs. Otherwise world-writable is refused, and
            // group-writable is fine only for the admin group.
            if folder.mode & 0o1002 == 0o1002 { continue }
            if folder.mode & 0o002 != 0
                || (folder.mode & 0o020 != 0 && folder.gid != adminGroup) {
                return ResearchLaunchProblem(
                    "The folder \(folder.path) can be changed by other users.")
            }
        }
        if file.isQuarantined {
            return ResearchLaunchProblem(
                "macOS marked this program as downloaded and has not approved it yet. Run it "
                    + "once from Terminal and allow it in System Settings > Privacy & Security, "
                    + "or, if you trust where it came from, remove the mark with "
                    + "`xattr -d com.apple.quarantine <file>`.")
        }
        return nil
    }

    // MARK: - Real files

    /// The facts of one path, without following a symbolic link. Nil when
    /// the path cannot be looked at.
    public static func facts(forPath path: String) -> ResearchFileFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let mode = UInt32(info.st_mode)
        let kind: ResearchFileFacts.Kind
        switch mode & 0o170000 {
        case 0o100000: kind = .regular
        case 0o040000: kind = .directory
        case 0o120000: kind = .symlink
        default: kind = .other
        }
        return ResearchFileFacts(
            path: path, kind: kind, uid: UInt32(info.st_uid), gid: UInt32(info.st_gid),
            mode: mode & 0o7777, isExecutable: access(path, X_OK) == 0,
            isQuarantined: hasQuarantineMark(path))
    }

    /// True when the file carries a download mark that macOS has not approved
    /// yet. After Gatekeeper passes a file, or the person allows it, macOS
    /// keeps the mark and sets the approved bit in it (see `needsApproval`).
    private static func hasQuarantineMark(_ path: String) -> Bool {
        #if canImport(Darwin)
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size + 1)
        let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        // A mark that cannot be read counts as not approved.
        guard read >= 0 else { return true }
        return quarantineNeedsApproval(String(decoding: buffer.prefix(read), as: UTF8.self))
        #else
        return false
        #endif
    }

    /// The value of `com.apple.quarantine` is `flags;time;agent;id`, flags in
    /// hex. Bit 0x40 is "approved by the user". A value that cannot be read
    /// counts as not approved.
    static func quarantineNeedsApproval(_ value: String) -> Bool {
        let field = value.split(separator: ";", omittingEmptySubsequences: false).first ?? ""
        guard let flags = UInt32(field, radix: 16) else { return true }
        return flags & 0x40 == 0
    }

    /// The program at `path`, with symbolic links resolved (Homebrew's
    /// `llama-server` is one), checked as `evaluate` says. Returns the
    /// resolved path, which is the one to start.
    public static func resolveAndCheck(_ path: String, uid: UInt32 = UInt32(getuid()))
        -> Result<String, ResearchLaunchProblem> {
        guard let resolved = realPath(path), let file = facts(forPath: resolved) else {
            return .failure(ResearchLaunchProblem("\(path) was not found."))
        }
        var folders = ["/"]
        var current = ""
        for part in resolved.split(separator: "/").dropLast() {
            current += "/" + part
            folders.append(current)
        }
        var ancestors: [ResearchFileFacts] = []
        for folder in folders {
            guard let facts = facts(forPath: folder) else {
                return .failure(ResearchLaunchProblem("The folder \(folder) cannot be looked at."))
            }
            ancestors.append(facts)
        }
        if let problem = evaluate(file: file, ancestors: ancestors, uid: uid) {
            return .failure(problem)
        }
        return .success(resolved)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - The key file

    /// Why llama-server may not be started with this key file, or nil. It
    /// must be a regular file (not a link) of the current user, with mode
    /// 0600, that holds exactly `key`. Without a working key file the server
    /// would start without a key, and any web page could use it.
    public static func keyFileProblem(path: String?, key: String,
                                      uid: UInt32 = UInt32(getuid())) -> ResearchLaunchProblem? {
        let unusable = "The key file for llama.cpp is not usable"
        guard let path else {
            return ResearchLaunchProblem("\(unusable): SandSeek has no key file.")
        }
        guard let file = facts(forPath: path), file.kind == .regular else {
            return ResearchLaunchProblem("\(unusable): \(path) is not a regular file.")
        }
        guard file.uid == uid, file.mode == 0o600 else {
            return ResearchLaunchProblem(
                "\(unusable): \(path) must belong to you and have mode 0600.")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == key else {
            return ResearchLaunchProblem("\(unusable): \(path) does not hold SandSeek's key.")
        }
        return nil
    }
}
