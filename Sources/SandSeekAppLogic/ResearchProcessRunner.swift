import Foundation

public struct ResearchProcessResult: Equatable, Sendable {
    public let status: Int32
    /// Standard output and standard error together.
    public let output: String
    /// True when the command was still running at its time limit and was
    /// ended by the runner.
    public let timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }

    /// The last non-empty lines, for an error message that fits on screen.
    public func tail(_ count: Int = 4) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(count).joined(separator: "\n")
    }
}

/// Runs a command-line tool to completion. Tests replace it with a fake; the
/// app uses `FoundationProcessRunner`.
public protocol ResearchProcessRunning: Sendable {
    /// Ends the process with SIGTERM if it is still running after `timeout`
    /// seconds, and with SIGKILL `killGrace` seconds later if it ignores that,
    /// so a hung `container` command cannot block the screen. The grace lets
    /// a script run its cleanup (an EXIT trap) after SIGTERM. Only the last
    /// `FoundationProcessRunner.maximumOutputBytes` bytes of its output are
    /// returned.
    func run(executable: URL,
             arguments: [String],
             environment: [String: String],
             timeout: TimeInterval,
             killGrace: TimeInterval) async throws -> ResearchProcessResult
}

public enum ResearchProcessGrace {
    /// Seconds between SIGTERM and SIGKILL for a direct `container` or
    /// `codesign` call.
    public static let direct: TimeInterval = 3
    /// The same for a run of the sandbox script, whose EXIT trap needs time to
    /// stop and remove the container. Only the script's own process (bash)
    /// is signalled, not a process group: Foundation's `Process` cannot start
    /// a child in a new group.
    public static let script: TimeInterval = 30
}

extension ResearchProcessRunning {
    /// Runs with the grace for a direct `container` or `codesign` call.
    public func run(executable: URL,
                    arguments: [String],
                    environment: [String: String],
                    timeout: TimeInterval) async throws -> ResearchProcessResult {
        try await run(executable: executable, arguments: arguments, environment: environment,
                      timeout: timeout, killGrace: ResearchProcessGrace.direct)
    }
}

public struct FoundationProcessRunner: ResearchProcessRunning {
    /// The most output a command gives back: its last 1 MiB. The end of a
    /// long build or start log is where the error is.
    public static let maximumOutputBytes = 1_048_576
    public init() {}

    /// Output goes to a temporary file rather than a pipe. `container system
    /// start` launches long-lived services, and a pipe they inherited would
    /// never reach end-of-file.
    public func run(executable: URL,
                    arguments: [String],
                    environment: [String: String],
                    timeout: TimeInterval,
                    killGrace: TimeInterval) async throws -> ResearchProcessResult {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sandseek-research-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: log)
        let progress = ProcessProgress()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { ended in
                progress.markFinished()
                try? handle.close()
                let output = Self.readTailAndDelete(log)
                continuation.resume(returning: ResearchProcessResult(
                    status: ended.terminationStatus, output: output,
                    timedOut: progress.timedOut))
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    // The flag keeps a reused process id from being signalled.
                    guard progress.markTimedOutIfRunning() else { return }
                    kill(pid, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                        if !progress.isFinished { kill(pid, SIGKILL) }
                    }
                }
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(throwing: error)
            }
        }
    }

    /// The last `maximumOutputBytes` bytes of the log as text, and the log
    /// file is deleted.
    private static func readTailAndDelete(_ log: URL) -> String {
        defer { try? FileManager.default.removeItem(at: log) }
        guard let reader = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? reader.close() }
        return tail(of: reader, limit: maximumOutputBytes)
    }

    /// The last `limit` bytes of what `reader` can read, decoded as UTF-8.
    static func tail(of reader: FileHandle, limit: Int) -> String {
        guard let size = try? reader.seekToEnd() else { return "" }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? reader.seek(toOffset: start)) != nil else { return "" }
        let data = (try? reader.read(upToCount: limit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The environment every program SandSeek starts runs with: `container`,
/// `codesign` and the sandbox script. It is built from a short list, never
/// filtered from the app's own environment, so nothing set in the shell or
/// by a launcher (`DYLD_*`, `BASH_ENV`, proxy variables, tokens) reaches them.
public enum ResearchCommandEnvironment {
    /// Only system folders. Every program is started by its full path, so this
    /// is for what those programs start in turn (`codesign`, `container`'s
    /// helpers, the script's `curl`, `tr`, `mktemp`).
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let language = "en_US.UTF-8"
    /// The names copied from the app's environment when they are set: where
    /// the user's files and temporary files are, and who the user is.
    static let inheritedNames = ["HOME", "USER", "LOGNAME", "TMPDIR"]
    /// The settings the sandbox script reads, passed on when set: the VM's
    /// DNS servers and the search engine's address.
    public static let sandboxScriptNames = ["SANDSEEK_DNS", "SEARXNG_URL"]

    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = ["PATH": path, "LANG": language]
        for name in inheritedNames {
            if let value = base[name], !value.isEmpty { environment[name] = value }
        }
        return environment
    }
}

private final class ProcessProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var didTimeOut = false

    var isFinished: Bool { lock.withLock { finished } }
    var timedOut: Bool { lock.withLock { didTimeOut } }

    func markFinished() { lock.withLock { finished = true } }

    /// True when the command was still running, now marked as timed out.
    func markTimedOutIfRunning() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            didTimeOut = true
            return true
        }
    }
}
