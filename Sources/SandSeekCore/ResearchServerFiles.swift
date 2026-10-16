import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The two files a started model server leaves behind: its log, and a small
// marker that says SandSeek started it, so that after a crash the next launch
// can find it again. Both are only for the person who runs SandSeek (mode
// 0600, in folders with mode 0700).

// MARK: - Log

/// What the server writes. One file, replaced on every start, never sent to
/// the model and never put into a report.
public enum ResearchServerLog {
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("SandSeek/Logs/model-server.log")
    }

    /// Makes a new, empty log for the server to write to. The folder is made
    /// with mode 0700 (and set to it if it existed); a link in its place is
    /// refused. An old file, or a link planted at the file's place, is
    /// removed first and the file is made fresh, so a link is never followed.
    /// The file is created close-on-exec: only the server gets it, as its
    /// output. A pipe is not used because nobody reads it, and the server
    /// would block when its buffer is full.
    public static func create(at url: URL) throws -> FileHandle {
        let folder = url.deletingLastPathComponent().path
        if let existing = ResearchExecutableCheck.facts(forPath: folder) {
            guard existing.kind == .directory else {
                throw ResearchLaunchProblem("\(folder) is not a folder, so the log cannot be kept.")
            }
        } else {
            try FileManager.default.createDirectory(
                atPath: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        unlink(url.path)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ResearchLaunchProblem(
                "The server log could not be created: \(String(cString: strerror(errno))).")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The last lines of the log, for an error message. Only the end of the
    /// file is read. The text is cleaned like any text from outside (a server
    /// can print what it was given), and lines that mention an API key are
    /// left out in case a build prints a part of it.
    public static func tail(at url: URL, lines: Int = 6, bytes: Int = 16_384) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return "" }
        var kept = ResearchText.terminalSafe(String(decoding: data, as: UTF8.self))
            .split(whereSeparator: \.isNewline)
        // The cut can fall inside the first line.
        if start > 0 { kept = Array(kept.dropFirst()) }
        return kept
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let lower = line.lowercased()
                return !line.isEmpty && !["api_key", "api-key", "apikey"].contains { lower.contains($0) }
            }
            .suffix(lines)
            .map { ResearchText.capped($0, limit: 300) }
            .joined(separator: "\n")
    }
}

// MARK: - Process identity

/// Which process a process id belongs to: when it started, and which program
/// it runs. A process id alone can be reused by another program.
public struct ResearchProcessIdentity: Equatable, Sendable {
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let path: String

    public init(startSeconds: UInt64, startMicroseconds: UInt64, path: String) {
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.path = path
    }

    /// The identity of the live process `pid`, or nil when there is none (or
    /// on a system without `proc_pidinfo`).
    public static func read(pid: Int32) -> ResearchProcessIdentity? {
        #if canImport(Darwin)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return ResearchProcessIdentity(
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            path: String(cString: buffer))
        #else
        return nil
        #endif
    }
}

// MARK: - Marker

/// "SandSeek started this server": written as soon as the server runs and
/// removed once it is confirmed gone. If SandSeek crashes, the file stays,
/// and the next launch takes the server over, but only if the process id, the
/// start time and the program all still match. It is never killed from here.
public struct ResearchServerMarker: Codable, Equatable, Sendable {
    public static let fileName = "model-server-started-by-app.json"

    /// `ResearchServerType.rawValue`: "tuff", "llamacpp" or "ollama".
    public let type: String
    public let port: Int
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let path: String

    public init(type: String, port: Int, pid: Int32, identity: ResearchProcessIdentity) {
        self.type = type
        self.port = port
        self.pid = pid
        startSeconds = identity.startSeconds
        startMicroseconds = identity.startMicroseconds
        path = identity.path
    }

    public var identity: ResearchProcessIdentity {
        ResearchProcessIdentity(
            startSeconds: startSeconds, startMicroseconds: startMicroseconds, path: path)
    }

    public static func load(from directory: URL) -> ResearchServerMarker? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(ResearchServerMarker.self, from: data)
    }

    /// Writes the file atomically, mode 0600, in a folder with mode 0700.
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(Self.fileName)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func remove(from directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
