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

    public var servicesReady: Bool {
        sandbox.state == .ready && server.state == .ready && !server.models.isEmpty
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

    public func ask(_ question: String, settings: ResearchRunSettings) {
        guard servicesReady else { return }
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
