import AppKit
import SwiftUI
import SandSeekAppLogic
import SandSeekCore
import UniformTypeIdentifiers

// MARK: - Steps

struct ResearchStepRow: View {
    let step: ResearchStep
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ResearchText.duration(step.elapsed))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step.kind {
        case .turn:
            Text(step.text).font(.callout.weight(.semibold))
        case .thinking:
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(step.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text("Thinking").font(.callout).foregroundStyle(.secondary)
            }
        case .searching:
            Text("Searching \(Text(step.text).font(.callout.monospaced()))")
                .font(.callout)
                .textSelection(.enabled)
        case .reading:
            Text("Reading \(Text(step.text).font(.callout.monospaced()))")
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        case .failed:
            Text(step.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var symbol: String {
        switch step.kind {
        case .turn: "circle.fill"
        case .thinking: "ellipsis.bubble"
        case .searching: "magnifyingglass"
        case .reading: "doc.text"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch step.kind {
        case .turn: AppTheme.accent
        case .thinking: .secondary
        case .searching: AppTheme.accent
        case .reading: .green
        case .failed: .orange
        }
    }
}

// MARK: - Folding sections

/// A section under the orange cautions that is folded until one click opens it.
struct ReportFoldSection<Content: View>: View {
    let title: String
    private let content: Content
    @State private var isExpanded = false

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // A macOS disclosure group centres narrow content; keep it at the
            // leading edge, under the title.
            content
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.caption).foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Report

struct ResearchReportView: View {
    let report: SavedResearchReport
    let markdownURL: URL
    let saveError: String?
    let proxy: ScrollViewProxy
    @State private var highlighted: Int?
    @State private var sourceToOpen: SavedResearchReport.Source?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.question)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if let reason = report.endedEarly {
                Label {
                    Text("This research ended early: \(reason). It has no answer; the pages read so far are listed below.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else if let notice = report.emptyAnswerNotice {
                Label {
                    Text(notice)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Text(ResearchAnswerFormatter.attributed(
                report.answer, sourceNumbers: Set(report.sources.map(\.number))))
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // Every link in the answer comes through here. Citation
                // numbers scroll to their source; nothing else opens.
                .environment(\.openURL, OpenURLAction { url in
                    if let number = ResearchAnswerFormatter.sourceNumber(from: url) {
                        show(number)
                    }
                    return .handled
                })
            ForEach(report.answerWarnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !report.figureCheckGroups.isEmpty {
                ReportFoldSection(title: "Figure check (\(report.unverifiedFigureCount))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.figureCheckGroups.enumerated()), id: \.offset) { _, group in
                            Text(group.intro)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                                Text("\u{2022} " + line)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if report.figureCheckMore > 0 {
                            Text("\u{2022} and \(report.figureCheckMore) more")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .id("figure-check-\(report.id)")
            }
            if !report.unreadablePages.isEmpty {
                ReportFoldSection(title: "Pages that could not be read (\(report.unreadablePages.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.unreadablePages.enumerated()), id: \.offset) { _, page in
                            Text("\u{2022} " + page.line)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .id("unreadable-pages-\(report.id)")
            }
            if !report.sources.isEmpty {
                Text("Sources").font(.headline)
                // Small cards side by side when there is room.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 10, alignment: .top)],
                    alignment: .leading, spacing: 10
                ) {
                    ForEach(report.sources) { source in
                        sourceCard(source).id("research-source-\(source.number)")
                    }
                }
            }
            if !report.searchQueries.isEmpty {
                Text("Searches").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(report.searchQueries.enumerated()), id: \.offset) { _, query in
                        Label(query, systemImage: "magnifyingglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let notice = report.singleSearchNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Label(footer, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Copy answer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        ResearchAnswerFormatter.plainText(report.answer), forType: .string)
                    note = "Copied."
                }
                .disabled(report.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Copies the answer as plain text.")
                Button("Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.markdown, forType: .string)
                    note = "Copied."
                }
                Button("Save As…", action: saveAs)
                Button("Export as PDF…") {
                    if let message = ReportPrinting.exportPDF(report) { note = message }
                }
                .help("Writes the question, the answer and the numbered sources to a PDF.")
                Button("Print…") { ReportPrinting.printReport(report) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([markdownURL])
                }
                .disabled(!FileManager.default.fileExists(atPath: markdownURL.path))
                if let message = saveError ?? note {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                }
            }
        }
        .confirmationDialog(
            "Open this source in your browser?",
            isPresented: Binding(
                get: { sourceToOpen != nil },
                set: { if !$0 { sourceToOpen = nil } }),
            presenting: sourceToOpen
        ) { source in
            Button("Open in Browser") {
                if let url = source.webURL { NSWorkspace.shared.open(url) }
                sourceToOpen = nil
            }
            Button("Cancel", role: .cancel) { sourceToOpen = nil }
        } message: { source in
            Text(source.webURL?.absoluteString ?? source.url)
        }
        .onChange(of: report.id) { note = nil }
        // The Print command in the File menu (⌘P) prints the report on screen.
        .focusedSceneValue(\.shownReport, report)
    }

    private var footer: String {
        var model = report.model
        if let server = report.serverDisplayName { model += " on " + server }
        return "Written from web pages by a local model (" + model
            + "). Check the sources before you rely on it."
    }

    /// One source as a small card: its number, the page's title, the site and
    /// the button that asks before opening it. Nothing from the page is loaded.
    private func sourceCard(_ source: SavedResearchReport.Source) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(source.number)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(AppTheme.accent, in: Circle())
                    .accessibilityLabel("Source \(source.number)")
                Text(source.title.isEmpty ? source.host : source.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(source.title.isEmpty ? source.host : source.title)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Text(source.host)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(ResearchText.url(source.url))
            Button("Open\u{2026}") { sourceToOpen = source }
                .controlSize(.small)
                .disabled(source.webURL == nil)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            highlighted == source.number
                ? AppTheme.accent.opacity(0.14) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10))
    }

    private func show(_ number: Int) {
        withAnimation(.smooth(duration: 0.25)) {
            proxy.scrollTo("research-source-\(number)", anchor: .center)
            highlighted = number
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if highlighted == number { highlighted = nil }
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Research report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.markdown.utf8).write(to: url, options: .atomic)
            note = "Saved."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// The report a window shows, so the File > Print command can reach it.
struct ShownReportKey: FocusedValueKey {
    typealias Value = SavedResearchReport
}

extension FocusedValues {
    var shownReport: SavedResearchReport? {
        get { self[ShownReportKey.self] }
        set { self[ShownReportKey.self] = newValue }
    }
}

/// File > Print…, for whichever report window or screen has focus.
struct PrintReportCommand: View {
    @FocusedValue(\.shownReport) private var report

    var body: some View {
        Button("Print…") {
            if let report { ReportPrinting.printReport(report) }
        }
        .keyboardShortcut("p")
        .disabled(report == nil)
    }
}
