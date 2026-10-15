import AppKit
import SandSeekAppLogic
import SwiftUI

/// Every saved report, newest first. Opening one shows it on the Research
/// screen, or in a window of its own while a question runs.
struct ReportsScreen: View {
    let workspace: ResearchWorkspace
    let onOpen: (SavedResearchReport) -> Void
    @State private var reportToDelete: SavedResearchReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(
                    title: "Reports",
                    subtitle: "Each finished question is saved here as a report you can open, copy or save as Markdown.")
                if let imported = workspace.importedFromTUFF, imported > 0 {
                    Label("\(imported) \(imported == 1 ? "report was" : "reports were") copied from TUFF's research screen. The originals were left where they are.",
                          systemImage: "tray.and.arrow.down")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = workspace.reports.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if workspace.reports.reports.isEmpty {
                    Text("No reports yet. Ask a question on the Research screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(workspace.reports.reports) { report in
                            row(report)
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Move this report to the Trash?",
            isPresented: Binding(
                get: { reportToDelete != nil },
                set: { if !$0 { reportToDelete = nil } }),
            presenting: reportToDelete
        ) { report in
            Button("Move to Trash", role: .destructive) {
                workspace.delete(report)
                reportToDelete = nil
            }
            Button("Cancel", role: .cancel) { reportToDelete = nil }
        } message: { report in
            Text(report.question)
        }
    }

    private func row(_ report: SavedResearchReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.question)
                    .font(.headline)
                    .lineLimit(2)
                Text(details(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open") { onOpen(report) }
            Button("Delete", role: .destructive) { reportToDelete = report }
                .disabled(workspace.run.isRunning)
        }
        .cardStyle()
    }

    private func details(_ report: SavedResearchReport) -> String {
        var model = report.model
        if let server = report.serverDisplayName { model += " on " + server }
        let sources = report.sources.count
        return report.createdAt.formatted(date: .abbreviated, time: .shortened)
            + " · " + model
            + " · \(sources) \(sources == 1 ? "source" : "sources")"
            + (report.endedEarly == nil ? "" : " · ended early")
    }
}
