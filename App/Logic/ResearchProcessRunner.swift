import Foundation

public struct ResearchProcessResult: Equatable, Sendable {
    public let status: Int32
    /// Standard output and standard error together.
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
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
    /// seconds, so a hung `container` command cannot block the screen.
    func run(executable: URL,
             arguments: [String],
             environment: [String: String],
             timeout: TimeInterval) async throws -> ResearchProcessResult
}

public struct FoundationProcessRunner: ResearchProcessRunning {
    public init() {}

    /// Output goes to a temporary file rather than a pipe. `container system
    /// start` launches long-lived services, and a pipe they inherited would
    /// never reach end-of-file.
    public func run(executable: URL,
                    arguments: [String],
                    environment: [String: String],
                    timeout: TimeInterval) async throws -> ResearchProcessResult {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuff-research-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: log)
        let finished = ProcessFinishedFlag()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { ended in
                finished.set()
                try? handle.close()
                let data = (try? Data(contentsOf: log)) ?? Data()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: ResearchProcessResult(
                    status: ended.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    // The flag keeps a reused process id from being signalled.
                    if !finished.isSet { kill(pid, SIGTERM) }
                }
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum ResearchCommandEnvironment {
    /// Apps opened from Finder get a minimal PATH, which leaves out where
    /// Apple `container` and Homebrew install their tools.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let extra = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var path: [String] = []
        for entry in existing + extra where !entry.isEmpty && !path.contains(entry) {
            path.append(entry)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}

private final class ProcessFinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
