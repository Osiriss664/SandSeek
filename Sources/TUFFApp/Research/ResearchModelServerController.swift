import Darwin
import Foundation
import Observation
import TUFFAppServer
import TUFFModelCatalog
import TUFFResearchCore

public struct ResearchServedModel: Equatable, Identifiable, Hashable, Sendable {
    /// The id the server routes by, such as `gemma-4-e4b-it`.
    public let id: String
    public let displayName: String

    public init(id: String) {
        self.id = id
        displayName = TUFFModelCatalog.all.first { $0.apiModelID == id }?.displayName ?? id
    }
}

/// The local model server research talks to. It uses whichever is there: the
/// packaged app's Background API, a server this screen started, or one
/// started in Terminal.
@MainActor @Observable
public final class ResearchModelServerController {
    public enum State: Equatable, Sendable {
        case off
        case starting
        case ready
        case stopping
        case failed(String)

        public var isBusy: Bool { self == .starting || self == .stopping }
    }

    public enum Owner: Equatable, Sendable {
        case none
        case backgroundAPI
        case app
        /// Answering, but started outside the app, so the app cannot stop it.
        case outside
    }

    public private(set) var state: State = .off
    public private(set) var owner: Owner = .none
    public private(set) var models: [ResearchServedModel] = []
    /// True when a server this screen started was still running from an
    /// earlier session that did not quit normally, and was taken over.
    public private(set) var adoptedFromLastRun = false
    /// Whether the Background API was already on when the app opened, so
    /// the screen can say that stopping here turns it off.
    public let backgroundAPIWasOn: Bool
    /// Where a server this screen started keeps its log.
    public let logURL: URL

    private let backgroundAPI: AppBackgroundAPIController
    private let transport: any ResearchHTTPTransport
    private let serverExecutable: URL?
    private let modelsRoot: URL?
    private var process: Process?
    /// A server this screen started in an earlier session, by the marker it
    /// left (process id and start time).
    private var adoptedMarker: ResearchServerMarker?
    private let stateDirectory: URL
    private let processInfo: (pid_t) -> ResearchProcessInfo?

    static let markerName = "server.pid"

    public init(backgroundAPI: AppBackgroundAPIController,
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 3),
                serverExecutable: URL? = ResearchModelServerController.findServerExecutable(),
                modelsRoot: URL? = ResearchModelServerController.preferredModelsRoot(),
                logURL: URL = ResearchModelServerController.defaultLogURL(),
                stateDirectory: URL = ResearchSandboxController.defaultStateDirectory(),
                processInfo: @escaping (pid_t) -> ResearchProcessInfo? = ResearchProcessInfo.read) {
        self.backgroundAPI = backgroundAPI
        self.stateDirectory = stateDirectory
        self.processInfo = processInfo
        backgroundAPIWasOn = backgroundAPI.isAvailable && backgroundAPI.settings.enabled
        self.transport = transport
        self.serverExecutable = serverExecutable
        self.modelsRoot = modelsRoot
        self.logURL = logURL
        // A crash or force-quit skips the cleanup at quit. The marker names
        // the server it left behind, which is taken over only if that
        // process is still that server (see `ResearchServerMarker.names`); a
        // marker without a start time is from an older version and is not.
        let marker = stateDirectory.appendingPathComponent(Self.markerName)
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let named = ResearchServerMarker.parse(text),
           named.names(processInfo(named.pid), executable: serverExecutable,
                       port: backgroundAPI.settings.port) {
            adoptedMarker = named
            adoptedFromLastRun = true
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private var markerURL: URL { stateDirectory.appendingPathComponent(Self.markerName) }

    private var appServerIsRunning: Bool {
        if process?.isRunning == true { return true }
        return adoptedServerIsRunning
    }

    /// Whether the server taken over from an earlier session is still running.
    private var adoptedServerIsRunning: Bool {
        guard let adoptedMarker else { return false }
        return adoptedMarker.names(processInfo(adoptedMarker.pid),
                                   executable: serverExecutable, port: port)
    }

    public var port: Int { backgroundAPI.settings.port }
    public var serverURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// True when the screen can start a server at all.
    public var canStart: Bool { backgroundAPI.isAvailable || serverExecutable != nil }

    public var modelsRootDescription: String? { modelsRoot?.path }

    public func refresh() async {
        guard !state.isBusy else { return }
        let listed = await listModels()
        guard !state.isBusy else { return }
        apply(listed)
    }

    private func apply(_ listed: [ResearchServedModel]?) {
        if let listed {
            models = listed
            state = .ready
            if appServerIsRunning {
                owner = .app
            } else if backgroundAPI.isAvailable && backgroundAPI.settings.enabled {
                owner = .backgroundAPI
            } else {
                owner = .outside
            }
        } else {
            models = []
            owner = .none
            if state == .ready { state = .off }
            if adoptedMarker != nil, !adoptedServerIsRunning {
                adoptedMarker = nil
                adoptedFromLastRun = false
                try? FileManager.default.removeItem(at: markerURL)
            }
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    /// The models the server lists, or nil when nothing answers.
    private func listModels() async -> [ResearchServedModel]? {
        guard let response = try? await transport.send(
            method: "GET", url: serverURL.appendingPathComponent("v1/models"), body: nil),
              response.status == 200,
              let reply = try? JSONDecoder().decode(ModelList.self, from: response.body)
        else { return nil }
        return reply.data.map { ResearchServedModel(id: $0.id) }
    }

    public func start() async {
        guard !state.isBusy, state != .ready else { return }
        state = .starting
        if backgroundAPI.isAvailable {
            backgroundAPI.update { $0.enabled = true }
        } else if let serverExecutable {
            do {
                try launch(serverExecutable)
            } catch {
                state = .failed("Could not start the model server: \(error.localizedDescription)")
                return
            }
        } else {
            state = .failed("This TUFF build has no model server next to it. "
                + "Build everything with `swift build -c release`.")
            return
        }
        // Loading the model list takes a moment; the model itself loads on
        // the first request.
        for _ in 0..<60 {
            if let listed = await listModels() {
                state = .starting
                apply(listed)
                if models.isEmpty {
                    state = .failed("The server is running but lists no installed models. "
                        + "Install one on the Models screen.")
                }
                return
            }
            if process != nil, process?.isRunning == false { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let detail = backgroundAPI.message ?? tailOfLog()
        state = .failed("The model server did not answer on 127.0.0.1:\(port)."
            + (detail.isEmpty ? "" : "\n\(detail)"))
        stopProcess()
    }

    public func stop() async {
        guard !state.isBusy else { return }
        switch owner {
        case .app:
            state = .stopping
            stopProcess()
            try? await Task.sleep(for: .milliseconds(300))
            state = .off
            owner = .none
            models = []
        case .backgroundAPI:
            state = .stopping
            backgroundAPI.update { $0.enabled = false }
            for _ in 0..<20 {
                guard await listModels() != nil else { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
            state = .off
            apply(await listModels())
        case .outside:
            state = .failed("This server was started outside TUFF. "
                + "Stop it where it runs, for example with Control-C in Terminal.")
        case .none:
            state = .off
        }
    }

    /// Ends a server this screen started, for app quit.
    public func stopWhenQuitting() {
        stopProcess()
    }

    private func launch(_ executable: URL) throws {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable
        var arguments = ["--port", String(port)]
        if let modelsRoot {
            arguments += ["--models-root", modelsRoot.path]
        }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] _ in
            try? log.close()
            Task { @MainActor in self?.processEnded() }
        }
        try process.run()
        self.process = process
        adoptedMarker = nil
        adoptedFromLastRun = false
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        // Without a start time the marker would never be trusted, so none is
        // written if the process cannot be read.
        if let started = processInfo(process.processIdentifier)?.startMicroseconds {
            let marker = ResearchServerMarker(
                pid: process.processIdentifier, startMicroseconds: started)
            try? Data(marker.text.utf8).write(to: markerURL, options: .atomic)
        }
    }

    private func processEnded() {
        process = nil
        try? FileManager.default.removeItem(at: markerURL)
        if owner == .app, state == .ready {
            state = .failed("The model server stopped. " + tailOfLog())
            owner = .none
            models = []
        }
    }

    private func stopProcess() {
        // Only a process that is checked to be that server is signalled; never
        // this app, which runs the same binary, nor the launch agent.
        if let adoptedMarker, adoptedServerIsRunning {
            kill(adoptedMarker.pid, SIGTERM)
        }
        adoptedMarker = nil
        adoptedFromLastRun = false
        try? FileManager.default.removeItem(at: markerURL)
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
    }

    private func tailOfLog() -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        let text = String(decoding: data.suffix(4_000), as: UTF8.self)
        return ResearchText.terminalSafe(
            text.split(separator: "\n").suffix(3).joined(separator: "\n"))
    }

    /// The `TUFFServer` built beside this app: next to the executable in a
    /// SwiftPM build, or in the bundle's `Resources/bin` when packaged.
    public nonisolated static func findServerExecutable(
        bundle: Bundle = .main,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        var candidates: [URL] = []
        if let executable = bundle.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("TUFFServer"))
        }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Resources/bin/TUFFServer"))
        return candidates.first { isExecutable($0.path) }
    }

    /// The models folder the app itself uses: `scratch/` in a checkout when
    /// it holds models, otherwise nil for the server's own default, which is
    /// the packaged app's Application Support folder.
    public nonisolated static func preferredModelsRoot(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let executable = bundle.executableURL else { return nil }
        var path = executable.deletingLastPathComponent().standardizedFileURL.path
        while true {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                let entries = (try? fileManager.contentsOfDirectory(atPath: scratch.path)) ?? []
                return entries.contains { $0.hasSuffix(".gturbo") } ? scratch : nil
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { return nil }
            path = parent
        }
    }

    public nonisolated static func defaultLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TUFF/research-server.log")
    }
}
