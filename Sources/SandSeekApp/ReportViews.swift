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
            } else if report.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text("The model stopped without writing an answer. This usually means it used up its token budget while thinking. Try again, or turn thinking off for this mode in Settings.")
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
            if !report.unknownCitations.isEmpty {
                Text("The answer cites \(report.unknownCitations.map { "[\($0)]" }.joined(separator: ", ")), which is not a page the research read.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.unverifiedFigureCount > 0 {
                Text("\(report.unverifiedFigureCount) \(report.unverifiedFigureCount == 1 ? "point" : "points") (figures, dates or names) could not be matched to the pages they cite. The saved report lists them under Figure check.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.budgetExhausted {
                Text("The research ran out of steps, so this answer may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.stoppedRepeatedSearches {
                Text("The research stopped early because the model kept repeating searches it had already run, so this answer may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.sources.isEmpty
                && !report.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No web page was read for this answer, so it comes from the model's memory or search previews and has no sources to check.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.answerCutOff {
                Text("The answer stopped at the model's length limit, so its end may be missing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.answerEndsMidSentence {
                Text("The answer seems to stop mid-sentence and may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if report.repeatedSourceEntries > 0, !report.sources.isEmpty {
                Text("The answer's own source list repeats \(report.repeatedSourceEntries) \(report.repeatedSourceEntries == 1 ? "entry" : "entries") it already lists; only the pages under Sources were read.")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                if report.searchQueries.count == 1 {
                    Text("Only one search was run, so other sources may have been missed.")
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
                .help("Copies the answer as plain text, without the sources.")
                Button("Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.markdown, forType: .string)
                    note = "Copied."
                }
                Button("Save As…", action: saveAs)
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
