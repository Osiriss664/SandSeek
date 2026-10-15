import Foundation
import Observation
import os
import SandSeekCore

/// Starts and stops the model server from the card, and remembers which
/// program and model to use. It starts only TUFFServer or llama-server, with
/// the fixed arguments of `ResearchServerLaunchPlan`, and it stops only a
/// server it started itself (or took over after a crash, see
/// `adoptLeftover`). A server started by hand is never touched.
///
/// A server SandSeek started can outlive SandSeek: macOS has no way to end a
/// child when its parent dies, so a crash, Force Quit or `kill -9` leaves it
/// running. SandSeek stops it when it is quit normally.
@MainActor @Observable
public final class ResearchServerLaunchController {
    public enum State: Equatable, Sendable {
        case idle
        /// The program is launched and SandSeek waits until it answers. A
        /// model can take minutes to load.
        case starting
        case running
        case stopping
        case failed(String)

        public var isBusy: Bool { self == .starting || self == .stopping }
    }

    /// The server SandSeek started. It is kept apart from the card's type and
    /// address: Stop still stops this process after the picker or the port was
    /// changed.
    public struct Owned: Equatable, Sendable {
        public let type: ResearchServerType
        public let port: Int
        public let pid: Int32
        /// The resolved path of the program that runs.
        public let path: String
        /// True for a server taken over from an earlier session.
        public let adopted: Bool
    }

    /// How long each wait is. The tests shorten them.
    public struct Timing: Sendable {
        public var poll: Duration
        public var tuffReady: Duration
        public var llamaReady: Duration
        public var stopGrace: Duration
        public var killGrace: Duration

        public init(poll: Duration = .milliseconds(700), tuffReady: Duration = .seconds(60),
                    llamaReady: Duration = .seconds(300), stopGrace: Duration = .seconds(5),
                    killGrace: Duration = .seconds(2)) {
            self.poll = poll
            self.tuffReady = tuffReady
            self.llamaReady = llamaReady
            self.stopGrace = stopGrace
            self.killGrace = killGrace
        }
    }

    static func programKey(_ type: ResearchServerType) -> String {
        "ResearchServerProgram-" + type.rawValue
    }
    /// llama.cpp: the model file. TUFF: the models folder.
    static func modelKey(_ type: ResearchServerType) -> String {
        type == .tuff ? "ResearchServerModels-tuff" : "ResearchServerModel-llamacpp"
    }

    public private(set) var state: State = .idle
    public private(set) var owned: Owned?
    /// The last lines of the server's log, when it failed.
    public private(set) var logTail = ""
    /// Why the last pick of a program, model or folder was refused.
    public private(set) var choiceProblem: String?
    public private(set) var programs: [ResearchServerType: String] = [:]
    public private(set) var models: [ResearchServerType: String] = [:]

    private let defaults: any ResearchSettingsStore
    private let launcher: any ResearchServerLaunching
    private let transport: any ResearchHTTPTransport
    private let stateDirectory: URL
    private let logURL: URL
    private let timing: Timing
    private let identityOf: @Sendable (Int32) -> ResearchProcessIdentity?
    private let checkProgram: @Sendable (String) -> Result<String, ResearchLaunchProblem>
    /// The running (or being stopped) process. Read by the quit path.
    @ObservationIgnored private var current: (any ResearchLaunchedServer)?
    /// Counts starts and stops, so a start that was stopped meanwhile ends
    /// without touching the state again.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var launchedAt = Date()
    @ObservationIgnored private var quitDeadline: Date?

    public init(defaults: any ResearchSettingsStore = UserDefaults.standard,
                launcher: any ResearchServerLaunching = FoundationServerLauncher(),
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 5),
                stateDirectory: URL = ResearchSandboxController.defaultStateDirectory(),
                logURL: URL = ResearchServerLog.defaultURL(),
                timing: Timing = Timing(),
                identityOf: @escaping @Sendable (Int32) -> ResearchProcessIdentity? =
                    { ResearchProcessIdentity.read(pid: $0) },
                checkProgram: @escaping @Sendable (String) -> Result<String, ResearchLaunchProblem> =
                    { ResearchExecutableCheck.resolveAndCheck($0) }) {
        self.defaults = defaults
        self.launcher = launcher
        self.transport = transport
        self.stateDirectory = stateDirectory
        self.logURL = logURL
        self.timing = timing
        self.identityOf = identityOf
        self.checkProgram = checkProgram
        for type in ResearchServerType.allCases where type.isAvailable {
            programs[type] = Self.saved(defaults, Self.programKey(type))
            models[type] = Self.saved(defaults, Self.modelKey(type))
        }
        adoptLeftover()
    }

    private static func saved(_ defaults: any ResearchSettingsStore, _ key: String) -> String? {
        defaults.savedString(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Choosing the program and the model

    /// Takes the program the person picked. For TUFF the pick becomes the
    /// `TUFFServer` beside it (see `ResearchServerLaunchPlan.tuffServerPath`);
    /// the path shown on the card is the one that will run. The program is
    /// checked now as well as at every start.
    public func chooseProgram(_ pick: String, for type: ResearchServerType) {
        do {
            let path: String
            switch type {
            case .tuff: path = try ResearchServerLaunchPlan.tuffServerPath(forPick: pick)
            case .llamacpp: path = try ResearchServerLaunchPlan.llamaServerPath(forPick: pick)
            case .ollama, .lmstudio: return
            }
            if case .failure(let problem) = checkProgram(path) { throw problem }
            programs[type] = path
            defaults.save(path, forKey: Self.programKey(type))
            choiceProblem = nil
        } catch {
            choiceProblem = String(describing: error)
        }
    }

    /// Takes the model file (llama.cpp, a `.gguf`) or the models folder
    /// (TUFF). An empty `pick` forgets the models folder; TUFFServer then uses
    /// the folder of the installed TUFF.
    public func chooseModel(_ pick: String, for type: ResearchServerType) {
        guard type.isAvailable else { return }
        if pick.isEmpty, type == .tuff {
            models[type] = nil
            defaults.save("", forKey: Self.modelKey(type))
            choiceProblem = nil
            return
        }
        do {
            try ResearchServerLaunchPlan.checkedPath(pick, "The path")
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: pick, isDirectory: &isFolder) else {
                throw ResearchLaunchProblem("\(pick) does not exist.")
            }
            if type == .llamacpp {
                guard !isFolder.boolValue, pick.lowercased().hasSuffix(".gguf") else {
                    throw ResearchLaunchProblem("Choose a .gguf model file.")
                }
            } else {
                guard isFolder.boolValue else {
                    throw ResearchLaunchProblem("Choose a folder for the models.")
                }
            }
            models[type] = pick
            defaults.save(pick, forKey: Self.modelKey(type))
            choiceProblem = nil
        } catch {
            choiceProblem = String(describing: error)
        }
    }

    // MARK: - Start

    /// Why Start is off, or nil when it can run. The card shows the text.
    public func startBlocker(for server: ResearchServerController) -> String? {
        if let owned {
            return "Stop the \(owned.type.displayName) server SandSeek started first "
                + "(16 GB: one model at a time)."
        }
        let type = server.serverType
        guard type.isAvailable else { return "\(type.displayName) support comes later." }
        guard let url = server.serverURL, let port = url.port else {
            return server.addressProblem ?? "The server address needs a port."
        }
        guard ["127.0.0.1", "localhost"].contains(url.host ?? "") else {
            return "Start uses 127.0.0.1; use the default address."
        }
        guard port >= ResearchServerLaunchPlan.lowestPort else {
            return "Start needs a port from \(ResearchServerLaunchPlan.lowestPort) up."
        }
        guard programs[type] != nil else { return "Choose the program first." }
        if type == .llamacpp, models[type] == nil { return "Choose a model file first." }
        return nil
    }

    /// Starts the chosen server and waits until it answers, then runs the
    /// card's normal Check (with the network check). Anything that is wrong
    /// ends in `.failed` with the reason and, if the server wrote anything,
    /// the end of its log.
    public func start(using server: ResearchServerController) async {
        guard !state.isBusy, owned == nil else { return }
        if let blocker = startBlocker(for: server) {
            state = .failed(blocker)
            return
        }
        let type = server.serverType
        guard let kind = type.kind, let port = server.serverURL?.port,
              let program = programs[type] else { return }
        attempt += 1
        let mine = attempt
        state = .starting
        logTail = ""
        ServiceLog.logger.notice("Server start requested: \(type.rawValue, privacy: .public)")

        // The files first: nothing is started from a program or key file that
        // is not as it should be.
        let resolved: String
        switch checkProgram(program) {
        case .success(let path): resolved = path
        case .failure(let problem): return fail(problem.message)
        }
        let plan: ResearchServerLaunchPlan
        do {
            plan = try makePlan(type: type, program: resolved, port: port, server: server)
        } catch {
            return fail(String(describing: error))
        }
        // A fresh look at the port, not the card's last state, which can be
        // ten seconds old.
        if let problem = await portProblem(port) { return fail(problem) }
        guard attempt == mine else { return }

        let launched: any ResearchLaunchedServer
        do {
            launched = try launcher.launch(plan, log: logURL)
        } catch {
            return fail("The server could not be started: \(error.localizedDescription)")
        }
        // Owned from the first moment, so Stop and Quit work while the model
        // loads.
        let pid = launched.pid
        current = launched
        launchedAt = Date()
        owned = Owned(type: type, port: port, pid: pid, path: resolved, adopted: false)
        ServiceLog.logger.notice(
            "Server started: \(type.rawValue, privacy: .public), pid \(pid, privacy: .public)")
        if let identity = launched.identity {
            try? ResearchServerMarker(type: type.rawValue, port: port, pid: pid, identity: identity)
                .write(to: stateDirectory)
        }
        launched.onExit { [weak self] exit in
            Task { @MainActor in self?.serverEnded(pid: pid, exit: exit) }
        }

        let timeout = kind == .tuff ? timing.tuffReady : timing.llamaReady
        let readyPath = kind == .tuff ? "/tuff/v1/status" : "/health"
        let deadline = ContinuousClock.now + timeout
        var lastStatus: Int?
        while true {
            guard attempt == mine, state == .starting else { return }
            if let exit = launched.exit {
                serverEnded(pid: pid, exit: exit)
                return
            }
            lastStatus = await answerStatus(port: port, path: readyPath)
            if lastStatus == 200 {
                // Only counts while our own process still runs: something
                // else may have answered on the port.
                guard attempt == mine, state == .starting else { return }
                if let exit = launched.exit {
                    serverEnded(pid: pid, exit: exit)
                    return
                }
                break
            }
            if ContinuousClock.now >= deadline {
                let seen = lastStatus.map(String.init) ?? "no answer"
                ServiceLog.logger.notice(
                    "Server not ready in time: last answer on \(readyPath, privacy: .public) was \(seen, privacy: .public)")
                // `.stopping` keeps the exit from being reported as a crash.
                state = .stopping
                let stopped = await terminateAndWait(launched)
                guard attempt == mine else { return }
                if stopped { clearOwned() }
                return fail("The server did not answer within \(timeout.components.seconds) seconds."
                    + (stopped ? " SandSeek stopped it." : ""), showLog: true)
            }
            try? await Task.sleep(for: timing.poll)
        }

        await server.check()
        guard attempt == mine, state == .starting else { return }
        if let exit = launched.exit {
            serverEnded(pid: pid, exit: exit)
            return
        }
        // The network check found the port open to the network. With
        // `--host 127.0.0.1` our server cannot be the one that accepted.
        if case .reachable(let warning) = server.exposure {
            state = .stopping
            let stopped = await terminateAndWait(launched)
            guard attempt == mine else { return }
            if stopped { clearOwned() }
            fail(warning + " Another program may be listening on this port."
                + (stopped ? " SandSeek stopped the server it started." : ""))
            await server.refresh()
            return
        }
        state = .running
    }

    private func makePlan(type: ResearchServerType, program: String, port: Int,
                          server: ResearchServerController) throws -> ResearchServerLaunchPlan {
        switch type {
        case .tuff:
            if let folder = models[type] {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder),
                      isFolder.boolValue else {
                    throw ResearchLaunchProblem("The models folder \(folder) does not exist.")
                }
            }
            return try .tuff(server: program, modelsRoot: models[type], port: port)
        case .llamacpp:
            guard let model = models[type] else {
                throw ResearchLaunchProblem("Choose a model file first.")
            }
            guard FileManager.default.fileExists(atPath: model) else {
                throw ResearchLaunchProblem("The model file \(model) does not exist.")
            }
            // Never without a working key file: a server started without a key
            // can be used by any web page.
            if let problem = server.keyProblem { throw ResearchLaunchProblem(problem) }
            if let problem = ResearchExecutableCheck.keyFileProblem(
                path: server.keyFilePath, key: server.apiKey) {
                throw problem
            }
            return try .llamacpp(
                server: program, model: model, port: port, keyFile: server.keyFilePath ?? "")
        case .ollama, .lmstudio:
            throw ResearchLaunchProblem("\(type.displayName) support comes later.")
        }
    }

    /// Nil when nothing answers on the port and the connection was refused;
    /// otherwise why Start is refused. A timeout also refuses: the port may
    /// be taken by something that does not speak HTTP.
    private func portProblem(_ port: Int) async -> String? {
        guard let url = URL(string: "http://\(ResearchServerLaunchPlan.host):\(port)/") else {
            return "The port is not usable."
        }
        do {
            _ = try await transport.send(method: "GET", url: url, body: nil, timeout: 2)
            return "A server already answers on 127.0.0.1:\(port); SandSeek did not start it. "
                + "Stop it first, or use another port."
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return nil
        } catch {
            return "Port \(port) on 127.0.0.1 may already be in use. Use another port."
        }
    }

    /// The HTTP status the route answered with; nil when nothing answered.
    private func answerStatus(port: Int, path: String) async -> Int? {
        guard let url = URL(string: "http://\(ResearchServerLaunchPlan.host):\(port)\(path)") else {
            return nil
        }
        let response = try? await transport.send(method: "GET", url: url, body: nil, timeout: 3)
        return response?.status
    }

    private func fail(_ message: String, showLog: Bool = false) {
        ServiceLog.logger.notice("Server problem: \(message, privacy: .public)")
        logTail = showLog ? ResearchServerLog.tail(at: logURL) : ""
        state = .failed(message)
    }

    // MARK: - The server ended

    /// The server SandSeek started ended by itself (a crash, the system
    /// ending it for memory, a failed start). A stop that SandSeek asked for
    /// also ends here, and is not reported as a failure.
    func serverEnded(pid: Int32, exit: ResearchServerExit) {
        guard let owned, owned.pid == pid else { return }
        let asked = state == .stopping
        let code: Int32 = exit.code ?? -1
        ServiceLog.logger.notice(
            "Server ended: pid \(pid, privacy: .public), code \(code, privacy: .public), by signal \(exit.bySignal, privacy: .public), SandSeek asked \(asked, privacy: .public)")
        let started = owned.adopted ? nil : Date().timeIntervalSince(launchedAt)
        clearOwned()
        guard !asked else { return }
        attempt += 1
        logTail = owned.adopted ? "" : ResearchServerLog.tail(at: logURL)
        state = .failed(Self.endedMessage(exit, secondsSinceStart: started))
    }

    nonisolated static func endedMessage(_ exit: ResearchServerExit,
                                         secondsSinceStart: TimeInterval?) -> String {
        var text = "The server SandSeek started ended"
        if let code = exit.code {
            text += exit.bySignal ? " (signal \(code))" : " (exit \(code))"
        }
        text += "."
        if exit.bySignal, exit.code == 9, let seconds = secondsSinceStart, seconds < 2 {
            text += " macOS ended it at once. That usually means Gatekeeper blocked the program, "
                + "or the Mac ran out of memory."
        }
        return text
    }

    private func clearOwned() {
        owned = nil
        current = nil
        ResearchServerMarker.remove(from: stateDirectory)
    }

    // MARK: - Stop

    /// Stops the server SandSeek started: SIGTERM, five seconds, then
    /// SIGKILL. Works while the server is still starting. Then looks at the
    /// server card again.
    public func stop(using server: ResearchServerController? = nil) async {
        guard let launched = current, state != .stopping else { return }
        let pid = launched.pid
        ServiceLog.logger.notice("Server stop requested: pid \(pid, privacy: .public)")
        attempt += 1
        state = .stopping
        if await terminateAndWait(launched) {
            clearOwned()
            state = .idle
            ServiceLog.logger.notice("Server stopped: pid \(pid, privacy: .public)")
        } else {
            ServiceLog.logger.notice("Server did not stop: pid \(pid, privacy: .public)")
            state = .failed("SandSeek could not stop the server (process \(launched.pid)). "
                + "Quit it in Activity Monitor.")
        }
        await server?.refresh()
    }

    private func terminateAndWait(_ launched: any ResearchLaunchedServer) async -> Bool {
        launched.terminate()
        if await waitForExit(launched, timing.stopGrace) { return true }
        launched.forceKill()
        return await waitForExit(launched, timing.killGrace)
    }

    private func waitForExit(_ launched: any ResearchLaunchedServer,
                             _ limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !launched.hasExited {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: - Quitting

    /// The first half of stopping when the app quits: sends SIGTERM and
    /// starts the five seconds. The workspace then stops the sandbox while the
    /// server shuts down, and calls `finishStopWhenQuitting`.
    public func beginStopWhenQuitting() {
        attempt += 1
        guard let launched = current, !launched.hasExited else { return }
        quitDeadline = Date().addingTimeInterval(
            TimeInterval(timing.stopGrace.components.seconds)
                + Double(timing.stopGrace.components.attoseconds) / 1e18)
        state = .stopping
        launched.terminate()
    }

    /// Waits until the server has ended, then sends SIGKILL if it has not.
    /// This runs on the main thread while the app quits, so it polls a flag
    /// that Foundation sets from its own thread; waiting for a main-actor
    /// callback here would never return. The marker goes only once the end is
    /// confirmed.
    public func finishStopWhenQuitting() {
        guard let launched = current else { return }
        if quitDeadline == nil { beginStopWhenQuitting() }
        while !launched.hasExited, Date() < (quitDeadline ?? Date()) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !launched.hasExited {
            launched.forceKill()
            let end = Date().addingTimeInterval(1)
            while !launched.hasExited, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        }
        if launched.hasExited {
            clearOwned()
            state = .idle
        }
    }

    // MARK: - After a crash

    /// Takes over a server an earlier SandSeek started and left running (a
    /// crash, Force Quit). Only a process whose id, start time and program all
    /// match the marker is taken over; then the card offers Stop and quitting
    /// stops it. Anything else just deletes the marker. Nothing is ever
    /// stopped here.
    public func adoptLeftover() {
        guard owned == nil, let marker = ResearchServerMarker.load(from: stateDirectory) else {
            return
        }
        guard let type = ResearchServerType(rawValue: marker.type), type.isAvailable,
              identityOf(marker.pid) == marker.identity else {
            ResearchServerMarker.remove(from: stateDirectory)
            return
        }
        let server = AdoptedServer(pid: marker.pid, identity: marker.identity, lookup: identityOf)
        current = server
        owned = Owned(type: type, port: marker.port, pid: marker.pid, path: marker.path, adopted: true)
        state = .running
        let pid = marker.pid
        server.onExit { [weak self] exit in
            Task { @MainActor in self?.serverEnded(pid: pid, exit: exit) }
        }
    }
}
