import AppKit
import SandSeekAppLogic
import SwiftUI

/// A saved report in a window of its own, opened while a question is running
/// (opening it on the Research screen would replace the run on screen). It
/// shows the report as text and changes nothing: the run, the cards and the
/// Research screen are not touched.
struct ReportWindowView: View {
    let workspace: ResearchWorkspace
    let reportID: UUID?

    private var report: SavedResearchReport? { workspace.reports.report(id: reportID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let report {
                        ResearchReportView(
                            report: report,
                            markdownURL: workspace.reports.markdownURL(for: report),
                            saveError: nil,
                            proxy: proxy)
                            .cardStyle()
                    } else {
                        Text("This report is no longer there. It may have been moved to the Trash.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .cardStyle()
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(28)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(report.map { String($0.question.prefix(80)) } ?? "Report")
    }
}
