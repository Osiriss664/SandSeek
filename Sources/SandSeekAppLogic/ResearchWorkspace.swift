import Foundation
import Observation

/// Everything the Research screen works with: the model server connection,
/// the sandbox, the run in progress, the saved reports and the presets.
@MainActor @Observable
public final class ResearchWorkspace {
    public let sandbox: ResearchSandboxController
    public let server: ResearchServerController
    public let reports: ResearchReportStore
    public let run: ResearchRunController
    public let presets: ResearchPresetStore
    /// The saved report on screen, when no run is.
    public var selectedReportID: UUID?
    /// How many reports the last import took over from TUFF; nil before it ran.
    public private(set) var importedFromTUFF: Int?
    /// The `sandbox.freshStarts` of the VM that a question last ran in.
    private var lastUsedStart: Int?
    private var isPreparingQuestion = false

    public init(sandbox: ResearchSandboxController,
                server: ResearchServerController,
                reports: ResearchReportStore,
                run: ResearchRunController,
                presets: ResearchPresetStore) {
        self.sandbox = sandbox
        self.server = server
        self.reports = reports
        self.run = run
        self.presets = presets
    }

    public convenience init(reportsDirectory: URL = ResearchReportStore.defaultDirectory(),
                            defaults: any ResearchSettingsStore = UserDefaults.standard) {
        let reports = ResearchReportStore(directory: reportsDirectory)
        self.init(
            sandbox: ResearchSandboxController(defaults: defaults),
            server: ResearchServerController(
                defaults: defaults,
                exposureCheck: ResearchServerController.networkExposureCheck),
            reports: reports,
            run: ResearchRunController(store: reports),
            presets: ResearchPresetStore(defaults: defaults))
    }

    /// Questions need the model server and a sandbox whose firewall and
    /// privileges were checked from outside the VM.
    public var servicesReady: Bool {
        sandbox.state == .ready && sandbox.protection == .verified
            && server.state == .ready && !server.models.isEmpty
            && server.serverURL != nil
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
    /// server that went away.
    public func refresh() async {
        if run.isRunning {
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
        guard servicesReady, !run.isRunning, !isPreparingQuestion else { return }
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

    /// Called when the app quits: stops what this app started. The model
    /// server is never ours to stop.
    public func shutdown() {
        run.stop()
        sandbox.stopWhenQuitting()
    }
}
