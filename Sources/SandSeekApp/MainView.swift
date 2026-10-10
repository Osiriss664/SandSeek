import SandSeekAppLogic
import SwiftUI

enum SidebarItem: Hashable {
    case research
    case reports
    case settings
}

/// The window: a sidebar (Research, Reports, Settings and the last few
/// reports) and the screen it picks.
struct MainView: View {
    let workspace: ResearchWorkspace
    @State private var selection: SidebarItem? = .research

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
                    workspace.open(report)
                    selection = .research
                }
            case .settings:
                SettingsScreen(presets: workspace.presets, server: workspace.server)
            }
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
            }
            let recent = Array(workspace.reports.reports.prefix(5))
            if !recent.isEmpty {
                Section("Recent reports") {
                    ForEach(recent) { report in
                        Button {
                            workspace.open(report)
                            selection = .research
                        } label: {
                            Text(report.question)
                                .lineLimit(2)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(report.question)
                        .disabled(workspace.run.isRunning)
                    }
                }
            }
        }
    }
}
