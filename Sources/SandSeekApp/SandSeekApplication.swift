import AppKit
import SandSeekAppLogic
import SwiftUI

// Run as a regular foreground app even when launched as a bare SwiftPM
// executable (no .app bundle): Dock icon, click-to-activate, full main menu
// with Quit (Cmd+Q).
private final class ForegroundAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app so quitting stops the sandbox and the model server this
    /// app started. A model server started by hand is never touched.
    @MainActor static var workspace: ResearchWorkspace?
    /// Turns a plain SIGTERM (`killall SandSeek`, some quit-all tools) into a
    /// normal quit, so that the model server SandSeek started is stopped too.
    @MainActor private static var termination: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.workspace?.shutdown()
        }
    }

    /// Before any window exists, so the chosen look shows from the first
    /// frame, also in a Report window macOS restores on its own.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.appearance = AppAppearance.stored.nsAppearance
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An empty handler, not SIG_IGN: an ignored signal stays ignored in
        // every program the app starts (container, the sandbox script, the
        // model server), and their timeouts end them with SIGTERM. A handler
        // is reset to the default in the started program.
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        Self.termination = source
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SandSeekMain: App {
    @NSApplicationDelegateAdaptor private var appDelegate: ForegroundAppDelegate
    @State private var workspace: ResearchWorkspace

    init() {
        let workspace = ResearchWorkspace()
        _workspace = State(initialValue: workspace)
        MainActor.assumeIsolated {
            ForegroundAppDelegate.workspace = workspace
        }
    }

    var body: some Scene {
        Window("SandSeek", id: "main") {
            MainView(workspace: workspace)
                .frame(minWidth: 980, minHeight: 640)
                // Once, when the window first appears: takes over the reports
                // TUFF's research screen saved (copies only; ids already
                // taken over are skipped).
                .task { await workspace.importTUFFReports() }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .printItem) { PrintReportCommand() } }
        // A saved report opened while a question runs, in a window of its own.
        // Declared after the main window, which is the one that opens at launch.
        WindowGroup("Report", for: UUID.self) { reportID in
            ReportWindowView(workspace: workspace, reportID: reportID.wrappedValue)
        }
        .defaultSize(width: 760, height: 720)
        // No File > New / Cmd-N for it: that would open a Report window with no
        // report. Reports open from the Reports list.
        .commandsRemoved()
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
