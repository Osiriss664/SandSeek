import AppKit
import SandSeekAppLogic
import SandSeekCore
import SwiftUI

/// Web research: a local model searches and reads the web through the
/// sandbox VM. Everything from the web is shown as plain text; nothing here
/// renders a page, loads an image or follows a link on its own.
struct ResearchWorkspaceView: View {
    let workspace: ResearchWorkspace
    @AppStorage("ResearchQuestion") private var question = ""
    @AppStorage("ResearchModel") private var selectedModel = ""
    @AppStorage("ResearchPreset") private var presetID: ResearchPresetID = .quick
    @State private var showsProgress = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenTitle(
                        title: "Research",
                        subtitle: "Ask a question. A model on this Mac searches and reads the web through a sealed sandbox.")
                    // Side by side when the window is wide enough, otherwise stacked.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 420), spacing: 18, alignment: .top)],
                        alignment: .leading, spacing: 18
                    ) {
                        ConnectionCard(server: workspace.server)
                        SandboxCard(workspace: workspace)
                    }
                    questionCard
                    results(proxy: proxy)
                }
                .frame(maxWidth: 1_300, alignment: .leading)
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await workspace.refresh()
                pickModelIfNeeded()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    // MARK: - Question

    private var running: Bool { workspace.run.isRunning }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A rounded-border TextField stays one line tall on macOS, so the
            // question gets a real editor. Return adds a line; ⌘Return asks.
            TextEditor(text: $question)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(minHeight: 96, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if question.isEmpty {
                        Text("Your question")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor)))
                .disabled(running)
                .accessibilityLabel("Your question")
            HStack(spacing: 14) {
                Picker("Model", selection: $selectedModel) {
                    if workspace.server.models.isEmpty {
                        Text("Connect a model server").tag("")
                    }
                    ForEach(workspace.server.models) { served in
                        Text(served.displayName).tag(served.id)
                    }
                }
                .fixedSize()
                .disabled(workspace.server.models.isEmpty || running)
                Picker("Mode", selection: $presetID) {
                    ForEach(ResearchPresetID.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(running)
                .help("Quick answer and Thorough use the values set under Settings.")
                Spacer(minLength: 8)
                if !workspace.servicesReady && !running {
                    Text(readinessHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if running {
                    Button("Stop", role: .cancel) { workspace.run.stop() }
                        .help("Stops this question. The model server and the sandbox keep running.")
                } else {
                    Button("Research", action: ask)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canAsk)
                }
            }
            Text(presetSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var presetSummary: String {
        let preset = workspace.presets.preset(presetID)
        return "Up to \(preset.maxSteps) steps, at least \(preset.minimumPages) pages read, "
            + "\(preset.searchResults) results per search, thinking "
            + (preset.thinking ? "on" : "off") + "."
    }

    /// Why the Research button is off, in a few words.
    private var readinessHint: String {
        if let note = workspace.sandbox.restartNote { return note }
        if workspace.server.state != .ready || workspace.server.models.isEmpty {
            return "Connect a model server first."
        }
        if workspace.sandbox.state != .ready { return "Start the sandbox first." }
        if workspace.sandbox.protection != .verified { return "Waiting for the sandbox check." }
        return "Check the model server address."
    }

    private var canAsk: Bool {
        workspace.servicesReady && !running
            && !selectedModel.isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        guard canAsk else { return }
        let settings = workspace.presets.preset(presetID).runSettings(model: selectedModel)
        let question = question
        showsProgress = true
        Task { await workspace.ask(question, settings: settings) }
    }

    /// Keeps the picked model when the server still lists it; otherwise takes
    /// the first one listed.
    private func pickModelIfNeeded() {
        let ids = workspace.server.models.map(\.id)
        guard let first = ids.first, !ids.contains(selectedModel) else { return }
        selectedModel = first
    }

    // MARK: - Progress and answer

    @ViewBuilder
    private func results(proxy: ScrollViewProxy) -> some View {
        if workspace.run.phase == .idle && workspace.shownReport == nil {
            Text("Each search, each page the model reads, and its thinking appear here while it works. The answer follows with numbered sources you can check.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    progressCard.frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
                    answerCard(proxy: proxy).frame(minWidth: 420, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) {
                    answerCard(proxy: proxy)
                    progressCard
                }
            }
        }
    }

    private var shownSteps: [ResearchStep] {
        if running || workspace.selectedReportID == nil {
            return workspace.run.steps.isEmpty
                ? (workspace.shownReport?.steps ?? []) : workspace.run.steps
        }
        return workspace.shownReport?.steps ?? []
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showsProgress.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showsProgress ? 90 : 0))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Progress").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showsProgress ? "Hide the steps" : "Show the steps")
                .accessibilityLabel(showsProgress ? "Hide progress" : "Show progress")
                Spacer()
                progressClock
            }
            if showsProgress {
                if shownSteps.isEmpty {
                    Text("Waiting for the model…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(shownSteps) { step in
                    ResearchStepRow(step: step)
                }
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop", role: .cancel) { workspace.run.stop() }
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var progressClock: some View {
        if running, let started = workspace.run.startedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(ResearchText.duration(context.date.timeIntervalSince(started)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if workspace.run.phase == .stopped {
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        } else if let report = workspace.shownReport {
            Text("\(report.endedEarly == nil ? "Finished" : "Ended early") in \(ResearchText.duration(report.durationSeconds))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func answerCard(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answer").font(.headline)
            switch workspace.run.phase {
            case .running:
                Text(workspace.run.question).font(.headline)
                Text("The answer appears here when the model is done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message) where workspace.selectedReportID == nil:
                Label {
                    Text(message).font(.callout).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                // What was read before the error is saved and shown.
                if let report = workspace.run.report {
                    reportView(report, proxy: proxy)
                }
            case .stopped where workspace.selectedReportID == nil:
                if let report = workspace.run.report {
                    reportView(report, proxy: proxy)
                } else {
                    Text("Stopped before an answer. Nothing was saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            default:
                if let report = workspace.shownReport {
                    reportView(report, proxy: proxy)
                }
            }
        }
        .cardStyle()
    }

    private func reportView(_ report: SavedResearchReport, proxy: ScrollViewProxy) -> some View {
        ResearchReportView(
            report: report,
            markdownURL: workspace.reports.markdownURL(for: report),
            saveError: report.id == workspace.run.report?.id ? workspace.run.saveError : nil,
            proxy: proxy)
    }
}
