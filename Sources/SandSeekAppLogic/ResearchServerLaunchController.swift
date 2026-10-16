import Foundation
import Observation
import os
import SandSeekCore

/// Starts and stops the model server from the card, and remembers which
/// program and model to use. It starts only TUFFServer, llama-server or
/// `ollama serve`, with the fixed arguments of `ResearchServerLaunchPlan`, and it stops only a
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
    /// The `.gguf` files and the TUFF models folders found on this Mac by
    /// `refreshFound`. They are only shown on the card; picking one goes
    /// through `chooseModel` like a pick from the file dialog.
    public private(set) var foundGGUF: [ResearchLocalGGUF] = []
    public private(set) var foundTUFF: [ResearchTUFFModelsFolder] = []
    /// True while a search for models runs.
    public private(set) var isLookingForModels = false
    /// Counts the ends of a server SandSeek started that SandSeek did not ask
    /// for. Whatever answers on the port afterwards is not SandSeek's (for
    /// Ollama it is often the menu-bar app's own server), so the workspace
    /// runs the card's Check once more when it sees this change.
    public private(set) var unaskedEnds = 0

    private let defaults: any ResearchSettingsStore
    private let launcher: any ResearchServerLaunching
    private let transport: any ResearchHTTPTransport
    private let stateDirectory: URL
    private let logURL: URL
    private let timing: Timing
    private let identityOf: @Sendable (Int32) -> ResearchProcessIdentity?
    private let checkProgram: @Sendable (String) -> Result<String, ResearchLaunchProblem>
    /// The children of a process, and how a signal is sent to a process id:
    /// for Ollama's model runners after a SIGKILL (see `forceKill`). The tests
    /// replace both, so they never look at or signal a real process.
    private let childrenOf: @Sendable (Int32) -> [Int32]
    private let sendSignal: @Sendable (Int32, Int32) -> Int32
    /// The running (or being stopped) process. Read by the quit path.
    @ObservationIgnored private var current: (any ResearchLaunchedServer)?
    /// Counts starts and stops, so a start that was stopped meanwhile ends
    /// without touching the state again.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var launchedAt = Date()
    @ObservationIgnored private var quitDeadline: Date?
    /// Counts the searches for models, so only the latest sets the results.
    @ObservationIgnored private var findAttempt = 0
    /// True while a search runs on `ResearchLocalModels`' queue.
    @ObservationIgnored private var isFinding = false
    /// A search asked for while one ran: the running one searches once more
    /// when it ends, for the latest request, instead of starting another.
    @ObservationIgnored private var findAgain: (type: ResearchServerType, home: String)?

    public init(defaults: any ResearchSettingsStore = UserDefaults.standard,
                launcher: any ResearchServerLaunching = FoundationServerLauncher(),
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 5),
                stateDirectory: URL = ResearchSandboxController.defaultStateDirectory(),
                logURL: URL = ResearchServerLog.defaultURL(),
                timing: Timing = Timing(),
                identityOf: @escaping @Sendable (Int32) -> ResearchProcessIdentity? =
                    { ResearchProcessIdentity.read(pid: $0) },
                checkProgram: @escaping @Sendable (String) -> Result<String, ResearchLaunchProblem> =
                    { ResearchExecutableCheck.resolveAndCheck($0) },
                childrenOf: @escaping @Sendable (Int32) -> [Int32] =
                    { ResearchProcessIdentity.childPIDs(of: $0) },
                sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }) {
        self.defaults = defaults
        self.launcher = launcher
        self.transport = transport
        self.stateDirectory = stateDirectory
        self.logURL = logURL
        self.timing = timing
        self.identityOf = identityOf
        self.checkProgram = checkProgram
        self.childrenOf = childrenOf
        self.sendSignal = sendSignal
        for type in ResearchServerType.allCases where type.canStart {
            programs[type] = Self.saved(defaults, Self.programKey(type))
            // Ollama has no model setting; `modelKey` would name llama.cpp's.
            if type != .ollama { models[type] = Self.saved(defaults, Self.modelKey(type)) }
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
            case .ollama: path = try ResearchServerLaunchPlan.ollamaPath(forPick: pick)
            case .lmstudio: return
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
        // Ollama keeps its models itself: there is nothing to choose.
        guard type.canStart, type != .ollama else { return }
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

    /// Looks for models already on this Mac: `.gguf` files for llama.cpp (and
    /// the chosen model file itself), TUFF models folders for TUFF (nothing
    /// for Ollama, which lists its own). The search only reads folders and
    /// runs on a queue of its own, one at a time: a request while one runs is
    /// noted, and the running one searches once more when it ends. Only the
    /// latest search sets the results, so one that was asked for earlier (for
    /// another type or an older model) changes nothing. A saved model path
    /// that `checkedPath` refuses is not looked at. `home` is a parameter so a
    /// test can use a temporary folder.
    public func refreshFound(for type: ResearchServerType,
                             home: String = ResearchServerLaunchPlan.userHome()) async {
        guard type == .llamacpp || type == .tuff else { return }
        findAttempt += 1
        isLookingForModels = true
        findAgain = (type, home)
        guard !isFinding else { return }
        isFinding = true
        while let request = findAgain {
            findAgain = nil
            let mine = findAttempt
            if request.type == .llamacpp {
                let roots = ResearchLocalModels.defaultGGUFRoots(home: request.home)
                let chosen = models[.llamacpp].flatMap { try? ResearchServerLaunchPlan.checkedPath($0, "") }
                let files = await ResearchLocalModels.onSearchQueue {
                    ResearchLocalModels.findGGUF(roots: roots, chosenModel: chosen)
                }
                if findAttempt == mine { foundGGUF = files }
            } else {
                let folders = ResearchLocalModels.defaultTUFFFolders(home: request.home, program: programs[.tuff])
                let found = await ResearchLocalModels.onSearchQueue {
                    ResearchLocalModels.findTUFFModels(folders: folders)
                }
                if findAttempt == mine { foundTUFF = found }
            }
        }
        isFinding = false
        isLookingForModels = false
    }

    // MARK: - Start

    /// Why Start is off, or nil when it can run. The card shows the text.
    public func startBlocker(for server: ResearchServerController) -> String? {
        if let owned {
            return "Stop the \(owned.type.displayName) server SandSeek started first "
                + "(16 GB: one model at a time)."
        }
        let type = server.serverType
        guard type.canStart else { return Self.cannotStartMessage(type) }
        guard let url = server.serverURL, let port = url.port else {
            return server.addressProblem ?? "The server address needs a port."
        }
        // Ollama is started on IPv4 loopback only, and `localhost` can reach
        // `::1` first, where another program may listen; so for Ollama the
        // address must say 127.0.0.1. TUFF and llama.cpp still take
        // `localhost` as before.
        let hosts = type == .ollama ? ["127.0.0.1"] : ["127.0.0.1", "localhost"]
        guard hosts.contains(url.host ?? "") else {
            return type == .ollama
                ? "Start uses 127.0.0.1; set the address to http://127.0.0.1:\(port)."
                : "Start uses 127.0.0.1; use the default address."
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
        if let problem = await portProblem(port) {
            return fail(type == .ollama
                ? problem + " If it is the Ollama menu-bar app, quit it from its menu first."
                : problem)
        }
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
        // The marker names only the program SandSeek started: a process
        // that runs anything else is never taken over after a crash.
        if let identity = launched.identity {
            if identity.path == plan.executable {
                try? ResearchServerMarker(type: type.rawValue, port: port, pid: pid, identity: identity)
                    .write(to: stateDirectory)
            } else {
                ServiceLog.logger.notice(
                    "No server marker: the running program is not the one started, pid \(pid, privacy: .public)")
            }
        }
        launched.onExit { [weak self] exit in
            Task { @MainActor in self?.serverEnded(pid: pid, exit: exit) }
        }

        let timeout = kind == .tuff ? timing.tuffReady : timing.llamaReady
        let readyPath: String
        switch kind {
        case .tuff: readyPath = "/tuff/v1/status"
        case .llamacpp: readyPath = "/health"
        case .ollama: readyPath = "/api/version"
        }
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
                // Only counts if our own process still runs one poll later.
                // Another program can take the port between the look at it
                // and our server's start, and answer here, while our server
                // fails to bind and ends a moment later; that end is seen
                // here, not taken for a server that is ready.
                try? await Task.sleep(for: timing.poll)
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
        case .ollama:
            // No model and no key: Ollama has neither a model to name nor an
            // API key; it keeps its models in its own folder.
            return try .ollama(server: program, port: port)
        case .lmstudio:
            throw ResearchLaunchProblem(Self.cannotStartMessage(type))
        }
    }

    /// Why Start is not offered for a type: it has no connector yet (LM Studio).
    static func cannotStartMessage(_ type: ResearchServerType) -> String {
        "\(type.displayName) support comes later."
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
        // The message can name files on this Mac, so it stays private in the log.
        ServiceLog.logger.notice("Server problem: \(message, privacy: .private)")
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
        unaskedEnds += 1
        logTail = owned.adopted ? "" : ResearchServerLog.tail(at: logURL)
        state = .failed(Self.endedMessage(
            exit, secondsSinceStart: started, type: owned.type, port: owned.port))
    }

    /// How long after its start an Ollama that ends with exit code 1 is taken
    /// to have found its port taken: it binds the port first thing.
    nonisolated static let earlyEnd: TimeInterval = 5

    nonisolated static func endedMessage(_ exit: ResearchServerExit,
                                         secondsSinceStart: TimeInterval?,
                                         type: ResearchServerType? = nil,
                                         port: Int? = nil) -> String {
        var text = "The server SandSeek started ended"
        if let code = exit.code {
            text += exit.bySignal ? " (signal \(code))" : " (exit \(code))"
        }
        text += "."
        if exit.bySignal, exit.code == 9, let seconds = secondsSinceStart, seconds < 2 {
            text += " macOS ended it at once. That usually means Gatekeeper blocked the program, "
                + "or the Mac ran out of memory."
        }
        guard type == .ollama else { return text }
        let address = port.map { "127.0.0.1:\($0)" } ?? "its port"
        if !exit.bySignal, exit.code == 1, let seconds = secondsSinceStart, seconds < earlyEnd {
            text += " Another program most likely took \(address) meanwhile, between SandSeek's "
                + "look at the port and the start (often the Ollama menu-bar app, which can open "
                + "at login)."
        } else {
            text += " If the Ollama menu-bar app was opened: it ends any other `ollama serve` "
                + "it finds and starts its own Ollama, with its own settings."
        }
        text += " An Ollama that answers on \(address) now was not started by SandSeek; it may "
            + "allow cloud models and listen on the network. Quit the Ollama menu-bar app and "
            + "start again from here, or press Check."
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
        forceKill(launched)
        return await waitForExit(launched, timing.killGrace)
    }

    /// SIGKILL for the server, and for the children it started from its own
    /// program: Ollama's model runners (`ollama runner`). On SIGTERM Ollama
    /// ends them itself; after a SIGKILL a runner would live on, on macOS, as
    /// an HTTP server on 127.0.0.1 without a key, with the model in memory.
    /// The children are listed while the server still runs (afterwards they
    /// belong to launchd), and each one is killed only if its id still names
    /// the same process (start time and program). TUFFServer and
    /// llama-server start no such children, so for them this finds nothing.
    /// A runner that the server starts between the listing and its own kill
    /// is not found; the log names every runner that was killed or could not
    /// be.
    private func forceKill(_ launched: any ResearchLaunchedServer) {
        var runners: [(pid: Int32, identity: ResearchProcessIdentity)] = []
        if !launched.hasExited, let path = launched.identity?.path {
            for child in childrenOf(launched.pid) {
                if let identity = identityOf(child), identity.path == path {
                    runners.append((pid: child, identity: identity))
                }
            }
        }
        launched.forceKill()
        for runner in runners {
            guard identityOf(runner.pid) == runner.identity else { continue }
            if sendSignal(runner.pid, SIGKILL) == 0 {
                ServiceLog.logger.notice(
                    "Server runner killed after the server: pid \(runner.pid, privacy: .public)")
            } else {
                ServiceLog.logger.warning(
                    "Server runner may be left running: pid \(runner.pid, privacy: .public)")
            }
        }
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
        let pid = launched.pid
        ServiceLog.logger.notice("Server stop when quitting: pid \(pid, privacy: .public)")
        launched.terminate()
    }

    /// Waits until the server has ended, then sends SIGKILL if it has not.
    /// This runs on the main thread while the app quits, so it polls a flag
    /// that Foundation sets from its own thread; waiting for a main-actor
    /// callback here would never return. The marker goes only once the end is
    /// confirmed.
    public func finishStopWhenQuitting() {
        guard let launched = current else { return }
        let pid = launched.pid
        if quitDeadline == nil { beginStopWhenQuitting() }
        while !launched.hasExited, Date() < (quitDeadline ?? Date()) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !launched.hasExited {
            forceKill(launched)
            let end = Date().addingTimeInterval(1)
            while !launched.hasExited, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        }
        if launched.hasExited {
            clearOwned()
            state = .idle
            ServiceLog.logger.notice("Server stopped when quitting: pid \(pid, privacy: .public)")
        } else {
            ServiceLog.logger.notice("Server did not stop when quitting: pid \(pid, privacy: .public)")
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
        guard let type = ResearchServerType(rawValue: marker.type), type.canStart,
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
