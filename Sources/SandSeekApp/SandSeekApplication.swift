import AppKit
import SandSeekAppLogic
import SwiftUI

// Run as a regular foreground app even when launched as a bare SwiftPM
// executable (no .app bundle): Dock icon, click-to-activate, full main menu
// with Quit (Cmd+Q).
private final class ForegroundAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app so quitting stops the sandbox this app started. The
    /// model server is never ours to stop.
    @MainActor static var workspace: ResearchWorkspace?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.workspace?.shutdown()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }
}
