import Foundation
import Observation
import SandSeekCore

/// Everything the Research screen works with: the model server connection,
/// the sandbox, the run in progress, the saved reports and the presets.
@MainActor @Observable
public final class ResearchWorkspace {
    public let sandbox: ResearchSandboxController
    public let server: ResearchServerController
    public let reports: ResearchReportStore
    public let run: ResearchRunController
    public let presets: ResearchPresetStore
    /// Starts and stops the model server from the card.
    public let launch: ResearchServerLaunchController
    /// The saved report on screen, when no run is.
    public var selectedReportID: UUID?
    /// How many reports the last import took over from TUFF; nil before it ran.
    public private(set) var importedFromTUFF: Int?
    /// The `sandbox.freshStarts` of the VM that a question last ran in.
    private var lastUsedStart: Int?
    /// True while a question is being prepared (the sandbox may restart), before
    /// the run starts.
    public private(set) var isPreparingQuestion = false
    /// True while `startEverything` runs.
    public private(set) var isStartingEverything = false
    /// What `startEverything` is doing now, in a few words; nil otherwise.
    public private(set) var startEverythingNote: String?

    public init(sandbox: ResearchSandboxController,
                server: ResearchServerController,
                reports: ResearchReportStore,
                run: ResearchRunController,
                presets: ResearchPresetStore,
                launch: ResearchServerLaunchController) {
        self.sandbox = sandbox
        self.server = server
        self.reports = reports
        self.run = run
        self.presets = presets
        self.launch = launch
    }

    public convenience init(reportsDirectory: URL = ResearchReportStore.defaultDirectory(),
                            defaults: any ResearchSettingsStore = UserDefaults.standard) {
        let reports = ResearchReportStore(directory: reportsDirectory)
        self.init(
            sandbox: ResearchSandboxController(
                defaults: defaults, secretFile: ResearchSandboxSecret.defaultFileURL),
            server: ResearchServerController(
                defaults: defaults,
                exposureCheck: ResearchServerController.networkExposureCheck),
            reports: reports,
            run: ResearchRunController(
                store: reports, sandboxSecretFile: ResearchSandboxSecret.defaultFileURL),
            presets: ResearchPresetStore(defaults: defaults),
            launch: ResearchServerLaunchController(defaults: defaults))
    }

    /// Questions need the model server and a sandbox whose firewall and
    /// privileges were checked from outside the VM.
    public var servicesReady: Bool {
        sandbox.state == .ready && sandbox.protection == .verified
            && server.state == .ready && !server.models.isEmpty
            && server.serverURL != nil
    }

    /// What the cards' folding needs to know (see `ResearchCardFolding`). A
    /// check or a protection check that is under way counts as "not known
    /// yet", and so does the restart the sandbox gets before each question,
    /// so the cards do not jump open and shut around a question.
    public var cardReadiness: ResearchCardReadiness {
        let serverReady: Bool?
        switch server.state {
        case .ready: serverReady = true
        case .off, .problem: serverReady = false
        case .notChecked, .checking: serverReady = nil
        }
        let sandboxReady: Bool?
        switch sandbox.state {
        case .ready:
            switch sandbox.protection {
            case .verified: sandboxReady = true
            case .notVerified: sandboxReady = false
            case .checking, .unknown: sandboxReady = nil
            }
        case .preparing, .starting:
            sandboxReady = sandbox.restartNote == nil ? false : nil
        case .off, .stopping, .failed:
            sandboxReady = false
        }
        return ResearchCardReadiness(server: serverReady, sandbox: sandboxReady)
    }

    /// True when a saved report should open in a window of its own: a
    /// question is running or being prepared, and opening the report on the
    /// Research screen would replace it.
    public var reportOpensInNewWindow: Bool {
        run.isRunning || isPreparingQuestion
    }

    /// Whether the "Start everything" button is shown: something is not ready,
    /// or the sequence is running.
    public var showsStartEverything: Bool {
        !servicesReady || isStartingEverything
    }

    /// Whether "Start everything" can be clicked.
    public var canStartEverything: Bool {
        !run.isRunning && !isPreparingQuestion && !isStartingEverything
    }

    /// True when a question already ran in the sandbox VM that is up now, or
    /// when that VM was left from an earlier session and may have been used.
    public var sandboxUsed: Bool {
        sandbox.adoptedFromLastRun || lastUsedStart == sandbox.freshStarts
    }

    /// Looks at both services (the model server only by its status route
    /// while it is ready; see `ResearchServerController.refresh`). The model
    /// server is left alone while a question runs: it is busy with that
    /// question, and a slow answer to a status check must not look like a
    /// server that went away. It is also left alone while SandSeek starts it:
    /// a llama.cpp server answers 503 while it loads its model, which the
    /// normal look would report as "not llama.cpp".
    public func refresh() async {
        if run.isRunning || launch.state == .starting {
            await sandbox.refresh()
        } else {
            async let sandboxRefresh: Void = sandbox.refresh()
            async let serverRefresh: Void = server.refresh()
            _ = await (sandboxRefresh, serverRefresh)
        }
    }

    /// Takes over the reports TUFF's research screen saved, once each. The
    /// originals stay where they are. The copying runs off the main thread.
    public func importTUFFReports(
        from source: URL = ResearchReportImporter.tuffReportsDirectory(),
        ledger: URL = ResearchReportImporter.defaultLedgerURL()
    ) async {
        let destination = reports.directory
        let outcome = await Task.detached {
            ResearchReportImporter.importReports(from: source, into: destination, ledger: ledger)
        }.value
        importedFromTUFF = outcome.copied
        if outcome.copied > 0 { reports.reload() }
    }

    /// A sandbox the app started and a question already used is replaced by a
    /// fresh VM first, so a parser exploit or the page cache of one question
    /// cannot reach the next; if that fails, no question is started. The
    /// restart is done before the run, not after it: `stop` sets the phase
    /// before the run's task ends, so a restart at the end of one run could
    /// kill the next run's VM. A sandbox started by hand is left alone. Then
    /// checks the sandbox's protection again, so a VM that changed since the
    /// last check is not used on the old result.
    public func ask(_ question: String, settings: ResearchRunSettings) async {
        guard servicesReady, !run.isRunning, !isPreparingQuestion,
              !isStartingEverything else { return }
        isPreparingQuestion = true
        defer { isPreparingQuestion = false }
        if sandbox.startedByApp && sandboxUsed {
            // `restart` verifies the protection of the new VM itself.
            guard await sandbox.restart() else { return }
        } else {
            await sandbox.recheckProtection()
        }
        guard servicesReady, !run.isRunning,
              let serverURL = server.serverURL, let connection = server.connection else { return }
        lastUsedStart = sandbox.freshStarts
        selectedReportID = nil
        run.start(
            question: question,
            settings: Self.applyingPromptBudget(
                to: settings, connection: connection, budget: presets.llamaPromptBudget),
            serverURL: serverURL,
            sandboxURL: sandbox.baseURL,
            connection: connection,
            authorization: server.authorization)
    }

    /// Gets everything ready for a question, in this order, and stops at the
    /// first thing that fails (its card shows the error):
    ///
    /// 1. The model server. Already ready: left alone. A program is chosen
    ///    under "Start it from SandSeek": it is started (a server that
    ///    answers already is found first, so none is started twice).
    ///    Otherwise the server is only checked.
    /// 2. The web sandbox. Already ready, or starting: not started again.
    /// 3. The security check, unless a passing result for this sandbox is
    ///    already there.
    ///
    /// Does nothing while a question runs or while this is already running.
    public func startEverything() async {
        guard canStartEverything else { return }
        isStartingEverything = true
        defer {
            isStartingEverything = false
            startEverythingNote = nil
        }

        // 1. The model server. A start or stop under way (from the card's own
        // buttons) is waited for, not repeated.
        await wait(while: { launch.state.isBusy })
        if Task.isCancelled { return }
        if server.state != .ready {
            startEverythingNote = "Looking for the model server…"
            await server.refresh()
        }
        if server.state != .ready {
            if launch.owned == nil, launch.programs[server.serverType] != nil {
                startEverythingNote = "Starting the model server…"
                await launch.start(using: server)
                if case .failed = launch.state { return }
            } else {
                startEverythingNote = "Checking the model server…"
                await server.check()
            }
        }
        guard server.state == .ready else { return }

        // 2. The sandbox. One that is starting or stopping is waited for; one
        // that already runs (the periodic look may not have seen it yet) is
        // found before anything is started.
        await wait(while: { sandbox.state.isBusy })
        if Task.isCancelled { return }
        if sandbox.state != .ready {
            startEverythingNote = "Looking for the sandbox…"
            await sandbox.refresh()
        }
        if sandbox.state != .ready {
            startEverythingNote = "Starting the sandbox…"
            await sandbox.start()
        }
        guard sandbox.state == .ready else { return }
        if sandbox.protection == .unknown { await sandbox.verifyProtection() }
        guard sandbox.protection == .verified else { return }

        // 3. The security check.
        if sandbox.selfTest?.passed != true {
            startEverythingNote = "Running the security check…"
            await sandbox.runSelfTest()
        }
    }

    /// Polls (on the main actor) until `busy` is false or the task is cancelled.
    private func wait(while busy: () -> Bool) async {
        while busy() {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }

    /// A llama.cpp server that does not say how large its context is gets the
    /// budget set in Settings, if there is one; otherwise the loop's small
    /// fallback applies. A budget already in the settings is kept.
    static func applyingPromptBudget(to settings: ResearchRunSettings,
                                     connection: ResearchServerConnection,
                                     budget: Int?) -> ResearchRunSettings {
        var settings = settings
        if connection.kind == .llamacpp, connection.contextTokens == nil,
           settings.contextCharacters == nil {
            settings.contextCharacters = budget
        }
        return settings
    }

    /// The report to show: the run's own while it is the latest thing done,
    /// otherwise the one picked in the sidebar.
    public var shownReport: SavedResearchReport? {
        if let selected = reports.report(id: selectedReportID) { return selected }
        return run.report
    }

    public func open(_ report: SavedResearchReport) {
        guard !run.isRunning else { return }
        run.reset()
        selectedReportID = report.id
    }

    public func delete(_ report: SavedResearchReport) {
        reports.delete(report)
        if selectedReportID == report.id { selectedReportID = nil }
        if run.report?.id == report.id { run.reset() }
    }

    /// Stops the question and the sandbox this app started.
    public func stopSandbox() async {
        run.stop()
        await sandbox.stop()
    }

    /// Called when the app quits: stops what this app started, the model
    /// server and the sandbox. The model server gets SIGTERM first, so that it
    /// shuts down while the sandbox is being stopped, and is waited for
    /// afterwards. A model server that someone else started is never touched.
    public func shutdown() {
        run.stop()
        launch.beginStopWhenQuitting()
        sandbox.stopWhenQuitting()
        launch.finishStopWhenQuitting()
    }
}
