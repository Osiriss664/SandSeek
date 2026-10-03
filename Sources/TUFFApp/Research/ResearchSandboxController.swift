import CryptoKit
import Foundation
import Observation
import TUFFResearchCore

/// One line of `Scripts/research_sandbox.sh selftest`.
public struct ResearchSelfTestCheck: Equatable, Identifiable, Sendable {
    public enum Outcome: Equatable, Sendable { case passed, failed, warning }
    public let id: Int
    public let section: String
    public let outcome: Outcome
    public let text: String
}

public struct ResearchSelfTestResult: Equatable, Sendable {
    public let passed: Bool
    public let checks: [ResearchSelfTestCheck]
    /// The script's own last line, such as "all sandbox checks passed".
    public let summary: String

    /// Reads the script's output. Failure lines can quote what the sandbox
    /// answered, which can include web text, so every line is cleaned.
    public static func parse(_ output: String, status: Int32) -> ResearchSelfTestResult {
        var checks: [ResearchSelfTestCheck] = []
        var section = ""
        var summary = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = ResearchText.terminalSafe(String(raw))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let outcome: ResearchSelfTestCheck.Outcome?
            let text: String
            if line.hasPrefix("  ok") {
                outcome = .passed
                text = String(trimmed.dropFirst(2))
            } else if line.hasPrefix("  FAIL") {
                outcome = .failed
                text = String(trimmed.dropFirst(4))
            } else if line.hasPrefix("  warn") {
                outcome = .warning
                text = String(trimmed.dropFirst(4))
            } else {
                outcome = nil
                text = trimmed
            }
            if let outcome {
                checks.append(ResearchSelfTestCheck(
                    id: checks.count,
                    section: section,
                    outcome: outcome,
                    text: text.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasSuffix(":") && !line.hasPrefix(" ") {
                section = String(trimmed.dropLast())
            } else {
                summary = trimmed
            }
        }
        let passed = status == 0 && !checks.isEmpty
            && !checks.contains { $0.outcome == .failed }
        return ResearchSelfTestResult(passed: passed, checks: checks, summary: summary)
    }
}

/// Starts and stops the web sandbox VM with the same commands as
/// `Scripts/research_sandbox.sh`, which it runs from the TUFF checkout. The
/// script holds every security option for the VM, so the app never builds
/// its own `container run` command.
@MainActor @Observable
public final class ResearchSandboxController {
    public enum State: Equatable, Sendable {
        case off
        case preparing
        case starting
        case ready
        case stopping
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .preparing, .starting, .stopping: true
            default: false
            }
        }
    }

    public static let imageName = "tuff-web-research:latest"
    public static let defaultURL = URL(string: "http://127.0.0.1:9000")!
    static let repositoryKey = "ResearchRepositoryPath"
    static let fingerprintKey = "ResearchSandboxImageFingerprint"

    public private(set) var state: State = .off
    public private(set) var repository: URL?
    public private(set) var selfTest: ResearchSelfTestResult?
    public private(set) var isRunningSelfTest = false
    /// True once this app started the sandbox, so quitting stops it again.
    public private(set) var startedByApp = false
    public let baseURL: URL

    private let runner: any ResearchProcessRunning
    private let transport: any ResearchHTTPTransport
    private let defaults: UserDefaults
    private let environment: [String: String]

    public init(baseURL: URL = ResearchSandboxController.defaultURL,
                runner: any ResearchProcessRunning = FoundationProcessRunner(),
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 3),
                defaults: UserDefaults = .standard,
                environment: [String: String] = ResearchCommandEnvironment.environment(),
                searchStart: [URL] = ResearchSandboxController.defaultSearchStart()) {
        self.baseURL = baseURL
        self.runner = runner
        self.transport = transport
        self.defaults = defaults
        self.environment = environment
        var candidates = searchStart
        if let saved = defaults.string(forKey: Self.repositoryKey) {
            candidates.insert(URL(fileURLWithPath: saved, isDirectory: true), at: 0)
        }
        repository = candidates.lazy.compactMap {
            Self.findRepository(startingAt: $0, fileExists: FileManager.default.fileExists(atPath:))
        }.first
    }

    /// Where a TUFF checkout is likely to be: above the running app when it
    /// was built from one, then the usual clone location.
    public nonisolated static func defaultSearchStart() -> [URL] {
        var starts: [URL] = []
        if let executable = Bundle.main.executableURL {
            starts.append(executable.deletingLastPathComponent())
        }
        starts.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/TUFF", isDirectory: true))
        return starts
    }

    public nonisolated static func findRepository(startingAt start: URL,
                                                  fileExists: (String) -> Bool) -> URL? {
        var path = start.standardizedFileURL.path
        while true {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            if fileExists(directory.appendingPathComponent("Scripts/research_sandbox.sh").path),
               fileExists(directory.appendingPathComponent("Sandbox/web-research/Containerfile").path) {
                return directory
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { return nil }
            path = parent
        }
    }

    /// Uses a folder the person picked. Returns false when it is not a TUFF
    /// checkout with the sandbox in it.
    @discardableResult
    public func chooseRepository(_ url: URL) -> Bool {
        guard let found = Self.findRepository(
            startingAt: url, fileExists: FileManager.default.fileExists(atPath:)) else {
            state = .failed("That folder is not a TUFF checkout with the web sandbox in it.")
            return false
        }
        repository = found
        defaults.set(found.path, forKey: Self.repositoryKey)
        if case .failed = state { state = .off }
        return true
    }

    private var script: URL? {
        repository?.appendingPathComponent("Scripts/research_sandbox.sh")
    }

    /// Asks the sandbox whether it answers. Leaves a start or stop in
    /// progress, and a failure message, alone.
    public func refresh() async {
        guard !state.isBusy else { return }
        let healthy = await isHealthy()
        guard !state.isBusy else { return }
        if healthy {
            state = .ready
        } else if state == .ready {
            state = .off
        }
    }

    private func isHealthy() async -> Bool {
        do {
            try await ResearchSandboxClient(baseURL: baseURL, transport: transport).checkHealth()
            return true
        } catch {
            return false
        }
    }

    /// Builds the image when it is missing or the sandbox's files changed
    /// since the last build, then starts a fresh VM.
    public func start() async {
        guard !state.isBusy, state != .ready else { return }
        guard let script, let repository else {
            state = .failed("Choose your TUFF folder so the app can find the web sandbox.")
            return
        }
        selfTest = nil
        let fingerprint = Self.fingerprint(
            of: repository.appendingPathComponent("Sandbox/web-research", isDirectory: true))
        if await needsBuild(fingerprint: fingerprint) {
            state = .preparing
            guard let built = await runScript(script, "build") else { return }
            guard built.status == 0 else {
                state = .failed(Self.message(for: built, doing: "build the sandbox image"))
                return
            }
            defaults.set(fingerprint, forKey: Self.fingerprintKey)
        }
        state = .starting
        guard let started = await runScript(script, "start") else { return }
        guard started.status == 0 else {
            state = .failed(Self.message(for: started, doing: "start the sandbox"))
            return
        }
        startedByApp = true
        state = await isHealthy() ? .ready
            : .failed("The sandbox started but does not answer on \(baseURL.absoluteString).")
    }

    public func stop() async {
        guard !state.isBusy else { return }
        guard let script else {
            state = .off
            return
        }
        state = .stopping
        selfTest = nil
        guard let stopped = await runScript(script, "stop") else { return }
        startedByApp = false
        state = stopped.status == 0 ? .off
            : .failed(Self.message(for: stopped, doing: "stop the sandbox"))
    }

    public func runSelfTest() async {
        guard state == .ready, !isRunningSelfTest, let script else { return }
        isRunningSelfTest = true
        defer { isRunningSelfTest = false }
        selfTest = nil
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, "selftest"],
                environment: environment)
            selfTest = ResearchSelfTestResult.parse(result.output, status: result.status)
        } catch {
            selfTest = ResearchSelfTestResult(
                passed: false, checks: [],
                summary: "The safety check could not run: \(error.localizedDescription)")
        }
    }

    /// Stops a sandbox this app started, without waiting, for app quit.
    public func stopWhenQuitting() {
        guard startedByApp, let script else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "stop"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func runScript(_ script: URL, _ command: String) async -> ResearchProcessResult? {
        do {
            return try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, command],
                environment: environment)
        } catch {
            state = .failed("Could not run the sandbox script: \(error.localizedDescription)")
            return nil
        }
    }

    private func needsBuild(fingerprint: String) async -> Bool {
        guard defaults.string(forKey: Self.fingerprintKey) == fingerprint else { return true }
        let inspected = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["container", "image", "inspect", Self.imageName],
            environment: environment)
        return inspected?.status != 0
    }

    static func message(for result: ResearchProcessResult, doing action: String) -> String {
        let output = ResearchText.terminalSafe(result.output)
        if result.status == 127 || output.contains("Apple container is not installed") {
            return "Apple container is not installed. Install it from github.com/apple/container/releases."
        }
        let tail = ResearchText.terminalSafe(result.tail())
        return tail.isEmpty ? "Could not \(action) (exit \(result.status))."
            : "Could not \(action):\n\(tail)"
    }

    /// A hash of every file in the sandbox folder, so a changed Containerfile,
    /// server or firewall rule triggers a rebuild.
    public nonisolated static func fingerprint(of directory: URL) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        var files: [(String, URL)] = []
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            if relative.contains("__pycache__") || relative.hasSuffix(".pyc") { continue }
            files.append((relative, url))
        }
        var hasher = SHA256()
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
