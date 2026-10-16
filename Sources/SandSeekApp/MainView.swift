import SandSeekAppLogic
import SwiftUI

enum SidebarItem: Hashable {
    case research
    case reports
    case settings
    case tips
}

/// The window: a sidebar (Research, Reports, Settings, Tips and the last few
/// reports) and the screen it picks.
struct MainView: View {
    let workspace: ResearchWorkspace
    @State private var selection: SidebarItem? = .research
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            switch selection ?? .research {
            case .research:
                ResearchWorkspaceView(workspace: workspace)
            case .reports:
                ReportsScreen(workspace: workspace) { report in
                    openReport(report)
                }
            case .settings:
                SettingsScreen(presets: workspace.presets, server: workspace.server)
            case .tips:
                TipsScreen()
            }
        }
    }

    /// Shows a saved report. While a question runs (or is being prepared) it
    /// gets a window of its own, so the run stays on screen; otherwise it
    /// opens on the Research screen.
    private func openReport(_ report: SavedResearchReport) {
        if workspace.reportOpensInNewWindow {
            openWindow(value: report.id)
        } else {
            workspace.open(report)
            selection = .research
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Research", systemImage: "magnifyingglass")
                    .tag(SidebarItem.research)
                Label("Reports", systemImage: "doc.text")
                    .tag(SidebarItem.reports)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
                Label("Tips", systemImage: "lightbulb")
                    .tag(SidebarItem.tips)
            }
            let recent = Array(workspace.reports.reports.prefix(5))
            if !recent.isEmpty {
                Section("Recent reports") {
                    ForEach(recent) { report in
                        Button {
                            openReport(report)
                        } label: {
                            Text(report.question)
                                .lineLimit(2)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(report.question)
                    }
                }
            }
        }
    }
}
