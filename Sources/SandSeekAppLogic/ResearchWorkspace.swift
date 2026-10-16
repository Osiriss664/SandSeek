import Foundation
import Observation
import os
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
    /// True while `stopEverything` runs.
    public private(set) var isStoppingEverything = false
    /// What `startEverything` is doing now, in a few words; nil otherwise.
    public private(set) var startEverythingNote: String?
    /// Why the last `startEverything` stopped before everything was ready, in
    /// plain words; nil when it got through or has not run. Stays until the
    /// next run.
    public private(set) var startEverythingStopNote: String?
    /// Remembers whether the cards were folded for the current stretch in
    /// which both are ready. Kept here, not in a screen, so switching to
    /// Reports or Settings and back does not fold an opened card again.
    @ObservationIgnored private var cardFolding = ResearchCardFolding()
    /// The `launch.unaskedEnds` that the Check after such an end was run for.
    @ObservationIgnored private var checkedUnaskedEnds = 0

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
    /// privileges were checked from outside the VM, and whose last security
    /// check (if one ran on this VM) passed.
    public var servicesReady: Bool {
        sandbox.state == .ready && sandbox.protection == .verified
            && !sandbox.securityCheckFailed
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
            // A failed security check keeps the card open, so it is seen.
            case .verified: sandboxReady = sandbox.securityCheckFailed ? false : true
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

    /// The folds the two cards should have now, given how they are. Call it
    /// whenever `cardReadiness` changes (see `ResearchCardFolding`).
    public func foldsAfterReadinessChange(
        current: ResearchCardFolding.Folds
    ) -> ResearchCardFolding.Folds {
        cardFolding.update(cardReadiness, folds: current)
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

    /// Whether "Start everything" can be clicked. Not while "Stop everything"
    /// runs.
    public var canStartEverything: Bool {
        !run.isRunning && !isPreparingQuestion && !isStartingEverything
            && !isStoppingEverything
    }

    /// Whether "Stop everything" can be clicked: there is a sandbox that is not
    /// off, or a model server that SandSeek started, and no start or stop is
    /// under way. A sandbox that is starting, preparing or stopping cannot be
    /// stopped (`stop` returns at once then), and neither can anything while a
    /// question is being prepared. A server started by hand does not count.
    public var canStopEverything: Bool {
        guard !isStartingEverything, !isStoppingEverything, !isPreparingQuestion else { return false }
        guard !sandbox.state.isBusy, launch.state != .stopping else { return false }
        return sandbox.state != .off || launch.owned != nil
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
            await checkAfterUnaskedEnd()
        }
    }

    /// After a server SandSeek started ended without being asked to (a
    /// crash, or the Ollama menu-bar app ending it and starting its own),
    /// whatever answers on the port next is not SandSeek's. The periodic look
    /// would show it as connected with no more than its status route, so the
    /// card's full Check, with the network check, runs on it once: a
    /// replacement that listens beyond loopback is flagged without a click.
    private func checkAfterUnaskedEnd() async {
        let ends = launch.unaskedEnds
        guard ends != checkedUnaskedEnds else { return }
        guard launch.owned == nil else {
            // SandSeek started a server again; its start ran the Check.
            checkedUnaskedEnds = ends
            return
        }
        switch server.state {
        case .ready, .problem:
            checkedUnaskedEnds = ends
            await server.check()
        case .notChecked, .checking, .off:
            // Nothing answers yet; the next look tries again.
            return
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
              !isStartingEverything, !isStoppingEverything else { return }
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
    /// first thing that fails (its card shows the error, and
    /// `startEverythingStopNote` says in a few words where to look):
    ///
    /// 1. The model server. Already ready: left alone. Off, with a program
    ///    chosen under "Start it from SandSeek" and a start that is allowed:
    ///    it is started (a server that answers already is found first, so
    ///    none is started twice). Otherwise the server is only checked. A
    ///    start, stop or Check that is under way is waited for. A server the
    ///    person has just stopped is not started again.
    /// 2. The web sandbox. Already ready, or starting: not started again. Its
    ///    protection check, if one is under way, is waited for.
    /// 3. The security check, unless a passing result for this sandbox is
    ///    already there.
    ///
    /// Does nothing while a question runs or while this is already running.
    public func startEverything() async {
        guard canStartEverything else { return }
        isStartingEverything = true
        startEverythingStopNote = nil
        ServiceLog.logger.notice("Start everything begins")
        defer {
            isStartingEverything = false
            startEverythingNote = nil
            ServiceLog.logger.notice("Start everything ends")
        }

        // 1. The model server. A start, stop or Check under way (from the
        // card's own buttons) is waited for, not repeated.
        let wasStopping = launch.state == .stopping
        await wait(while: { launch.state.isBusy || server.state.isBusy })
        if Task.isCancelled { return }
        if wasStopping {
            // The person stopped the server on purpose: do not undo that.
            startEverythingStopNote = "You just stopped the model server, so it was left off. "
                + "Start it from its card."
            return
        }
        if server.state != .ready {
            startEverythingNote = "Looking for the model server\u{2026}"
            await server.refresh()
        }
        if server.state != .ready {
            if server.state == .off, launch.owned == nil,
               launch.startBlocker(for: server) == nil {
                startEverythingNote = "Starting the model server\u{2026}"
                await launch.start(using: server)
                if case .failed = launch.state {
                    startEverythingStopNote = "The model server did not start: open its card."
                    return
                }
            } else {
                startEverythingNote = "Checking the model server\u{2026}"
                await server.check()
            }
        }
        guard server.state == .ready else {
            startEverythingStopNote = "The model server is not ready: open its card."
            return
        }

        // 2. The sandbox. One that is starting or stopping is waited for; one
        // that already runs (the periodic look may not have seen it yet) is
        // found before anything is started.
        await wait(while: { sandbox.state.isBusy })
        if Task.isCancelled { return }
        if sandbox.state != .ready {
            startEverythingNote = "Looking for the sandbox\u{2026}"
            await sandbox.refresh()
        }
        if sandbox.state != .ready {
            startEverythingNote = "Starting the sandbox\u{2026}"
            await sandbox.start()
        }
        // A protection check under way (this one's or the periodic look's) is
        // waited for, then decides.
        await wait(while: { sandbox.protection == .checking })
        if Task.isCancelled { return }
        guard sandbox.state == .ready else {
            startEverythingStopNote = "The sandbox is not running: open its card."
            return
        }
        if sandbox.protection == .unknown { await sandbox.verifyProtection() }
        guard sandbox.protection == .verified else {
            startEverythingStopNote = "The sandbox is not verified: open its card."
            return
        }

        // 3. The security check. One the person started is waited for.
        await wait(while: { sandbox.isRunningSelfTest })
        if Task.isCancelled { return }
        if sandbox.selfTest?.passed != true {
            startEverythingNote = "Running the security check\u{2026}"
            await sandbox.runSelfTest()
        }
        if sandbox.selfTest?.passed != true {
            startEverythingStopNote = "The security check did not pass: open the sandbox card."
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

    /// Stops the question that is running, and the sandbox: this app's own, or
    /// one nobody holds the lock for any more. A sandbox that another SandSeek
    /// holds the lock for (also the command line's) is left running, because
    /// `ResearchSandboxController.stop` acts only for the lock holder it
    /// recorded after its own start.
    public func stopSandbox() async {
        ServiceLog.logger.notice(
            "Stopping the question and the sandbox (question running: \(self.run.isRunning, privacy: .public))")
        run.stop()
        await sandbox.stop()
    }

    /// Stops the question in progress, the sandbox (as `stopSandbox` does),
    /// and the model server, but the server only if SandSeek
    /// started it; one started by hand keeps running. The server and the
    /// sandbox are stopped together, so the slower one does not wait for the
    /// other. Does nothing while `startEverything` runs, a stop is under way,
    /// or the sandbox is busy.
    public func stopEverything() async {
        guard canStopEverything else { return }
        isStoppingEverything = true
        let stopsServer = launch.owned != nil
        ServiceLog.logger.notice(
            "Stop everything begins (SandSeek started the server: \(stopsServer, privacy: .public))")
        defer {
            isStoppingEverything = false
            ServiceLog.logger.notice("Stop everything ends")
        }
        if stopsServer {
            async let serverStop: Void = launch.stop(using: server)
            async let sandboxStop: Void = stopSandbox()
            _ = await (serverStop, sandboxStop)
        } else {
            await stopSandbox()
        }
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
