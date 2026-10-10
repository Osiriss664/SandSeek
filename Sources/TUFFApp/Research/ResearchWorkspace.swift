import Foundation
import Observation
import TUFFAppServer

/// Everything the Research screen works with: the two local services, the
/// run in progress and the saved reports.
@MainActor @Observable
public final class ResearchWorkspace {
    public let sandbox: ResearchSandboxController
    public let server: ResearchModelServerController
    public let reports: ResearchReportStore
    public let run: ResearchRunController
    /// The saved report on screen, when no run is.
    public var selectedReportID: UUID?
    /// The `sandbox.freshStarts` of the VM that a question last ran in.
    private var lastUsedStart: Int?
    private var isPreparingQuestion = false

    public init(sandbox: ResearchSandboxController,
                server: ResearchModelServerController,
                reports: ResearchReportStore,
                run: ResearchRunController) {
        self.sandbox = sandbox
        self.server = server
        self.reports = reports
        self.run = run
    }

    public convenience init(backgroundAPI: AppBackgroundAPIController,
                            reportsDirectory: URL = ResearchReportStore.defaultDirectory()) {
        let reports = ResearchReportStore(directory: reportsDirectory)
        self.init(
            sandbox: ResearchSandboxController(),
            server: ResearchModelServerController(backgroundAPI: backgroundAPI),
            reports: reports,
            run: ResearchRunController(store: reports))
    }

    /// Questions need both services, and a sandbox whose firewall and
    /// privileges were checked from outside the VM.
    public var servicesReady: Bool {
        sandbox.state == .ready && sandbox.protection == .verified
            && server.state == .ready && !server.models.isEmpty
    }

    /// True when a question already ran in the sandbox VM that is up now, or
    /// when that VM was left from an earlier session and may have been used.
    public var sandboxUsed: Bool {
        sandbox.adoptedFromLastRun || lastUsedStart == sandbox.freshStarts
    }

    public var anyServiceOn: Bool {
        sandbox.state != .off || server.state != .off
    }

    public func refresh() async {
        async let sandboxRefresh: Void = sandbox.refresh()
        async let serverRefresh: Void = server.refresh()
        _ = await (sandboxRefresh, serverRefresh)
    }

    public func startServices() async {
        async let sandboxStart: Void = sandbox.start()
        async let serverStart: Void = server.start()
        _ = await (sandboxStart, serverStart)
    }

    public func stopServices() async {
        run.stop()
        async let sandboxStop: Void = sandbox.stop()
        async let serverStop: Void = server.stop()
        _ = await (sandboxStop, serverStop)
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
        guard servicesReady, !run.isRunning else { return }
        lastUsedStart = sandbox.freshStarts
        selectedReportID = nil
        run.start(
            question: question,
            settings: settings,
            serverURL: server.serverURL,
            sandboxURL: sandbox.baseURL)
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

    /// Called when the app quits: stops what this app started.
    public func shutdown() {
        run.stop()
        server.stopWhenQuitting()
        sandbox.stopWhenQuitting()
    }
}
