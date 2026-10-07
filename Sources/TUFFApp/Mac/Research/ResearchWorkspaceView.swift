import AppKit
import SwiftUI
import TUFFAppCore
import TUFFAppResearch
import TUFFMacPresentation
import TUFFResearchCore
import UniformTypeIdentifiers

/// Web research: a local model searches and reads the web through the
/// sandbox VM. Everything from the web is shown as plain text; nothing here
/// renders a page, loads an image or follows a link on its own.
struct ResearchWorkspaceView: View {
    let model: AppModel
    let research: ResearchWorkspace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("ResearchQuestion") private var question = ""
    @AppStorage("ResearchModel") private var selectedModel = ""
    @AppStorage("ResearchShowThinking") private var showThinking = true
    @AppStorage("ResearchMaxSteps") private var maxSteps = ResearchOptions().maxSteps
    @AppStorage("ResearchPageCharacters") private var pageCharacters = 3_000
    // The same options as `tuff research`; 0 and "auto" mean its default.
    @AppStorage("ResearchThinking") private var thinking = "auto"
    @AppStorage("ResearchMaxTokens") private var maxTokens = 0
    @AppStorage("ResearchContextCharacters") private var contextCharacters = 0
    @AppStorage("ResearchSearchResults") private var searchResults = ResearchOptions().searchResults
    @AppStorage("ResearchToolCalls") private var toolCalls = ResearchOptions().maxToolCallsPerTurn
    @AppStorage("ResearchMinimumPages") private var minimumPages = ResearchOptions().minimumPagesRead
    @AppStorage("ResearchAutoOpenPages") private var autoOpenPages = true
    @AppStorage("ResearchNudges") private var nudges = true
    @AppStorage("ResearchRewrite") private var rewrite = true
    @AppStorage("ResearchStepTimeout") private var stepTimeout = ResearchOptions.defaultStepTimeoutMinutes
    @AppStorage("ResearchThinkingLimit") private var thinkingLimit = ResearchOptions.defaultThinkingMinutes
    @State private var showsOptions = false
    @State private var showsProgress = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkspaceTitle(
                        title: "Research",
                        subtitle: "Ask a question. A model on this Mac searches and reads the web through a sealed sandbox.")
                    ResearchServicesCard(model: model, research: research)
                    composerCard
                    results(proxy: proxy)
                }
                .frame(maxWidth: 1_100, alignment: .leading)
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled {
                await research.refresh()
                pickModelIfNeeded()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    // MARK: - Question

    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A rounded-border TextField stays one line tall on macOS, so the
            // question gets a real editor. Return adds a line; ⌘Return asks.
            TextEditor(text: $question)
                .appFont(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(minHeight: 96, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if question.isEmpty {
                        Text("Your question")
                            .appFont(.body)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor)))
                .disabled(research.run.isRunning)
                .accessibilityLabel("Your question")
                .accessibilityIdentifier("research.question")
            HStack(spacing: 14) {
                Picker("Model", selection: $selectedModel) {
                    if research.server.models.isEmpty {
                        Text("Start the model server").tag("")
                    }
                    ForEach(research.server.models) { served in
                        Text(served.displayName).tag(served.id)
                    }
                }
                .fixedSize()
                .disabled(research.server.models.isEmpty || research.run.isRunning)
                Stepper(value: $maxSteps, in: ResearchOptions.maxStepsRange) {
                    Text("Steps: \(maxSteps)").appFont(.body.monospacedDigit())
                }
                .fixedSize()
                .disabled(research.run.isRunning)
                .help("How many search and read rounds the model may take before it must answer. The default is \(ResearchOptions().maxSteps), the same as tuff research.")
                Toggle("Show thinking", isOn: $showThinking)
                    .disabled(research.run.isRunning)
                    .help("Turns the model's reasoning on and shows it with the progress. It is never added to the report.")
                Button(showsOptions ? "Fewer Options" : "More Options") {
                    showsOptions.toggle()
                }
                .buttonStyle(.link)
                Spacer(minLength: 8)
                if !research.servicesReady && !research.run.isRunning {
                    Text(research.sandbox.state == .ready && research.server.state == .ready
                         ? "Waiting for the sandbox check." : "Start both services first.")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
                if research.run.isRunning {
                    Button("Stop Research", role: .cancel) { research.run.stop() }
                        .help("Stops this question. The model server and web sandbox keep running; use Stop Both to end them.")
                } else {
                    Button("Research", action: ask)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canAsk)
                }
            }
            if showsOptions {
                optionsGrid
                    .disabled(research.run.isRunning)
            }
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    /// The `tuff research` options, under the same names. Limits that protect
    /// the Mac (the sandbox, its firewall, fetch sizes and timeouts) are not
    /// here: they are fixed.
    private var optionsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Picker("Thinking", selection: $thinking) {
                    Text("Model default").tag("auto")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .fixedSize()
                .help("Reasoning on or off, as --thinking. Show thinking turns it on unless it is Off here.")
                Picker("Token limit per step", selection: $maxTokens) {
                    Text("Automatic").tag(0)
                    ForEach([2_048, 4_096, 8_192, 16_384], id: \.self) { size in
                        Text(size.formatted()).tag(size)
                    }
                }
                .fixedSize()
                .help("Tokens the model may write per step, as --max-tokens. Automatic is 2,048, or 8,192 with reasoning on.")
            }
            GridRow {
                Picker("Page text per read", selection: $pageCharacters) {
                    ForEach([2_000, 3_000, 5_000, 8_000], id: \.self) { size in
                        Text("\(size.formatted()) characters").tag(size)
                    }
                }
                .fixedSize()
                .help("As --page-chars.")
                Picker("Prompt budget", selection: $contextCharacters) {
                    Text("From the model").tag(0)
                    ForEach([8_000, 16_000, 32_000, 64_000], id: \.self) { size in
                        Text("\(size.formatted()) characters").tag(size)
                    }
                }
                .fixedSize()
                .help("How long the conversation may grow before older results are shortened, as --context-chars.")
            }
            GridRow {
                Stepper(value: $searchResults, in: ResearchOptions.searchResultsRange) {
                    Text("Results per search: \(searchResults)").appFont(.body.monospacedDigit())
                }
                .fixedSize()
                .help("As --search-results.")
                Stepper(value: $toolCalls, in: ResearchOptions.toolCallsRange) {
                    Text("Tool calls per step: \(toolCalls)").appFont(.body.monospacedDigit())
                }
                .fixedSize()
                .help("Searches and page reads the model may ask for in one step, as --tool-calls.")
            }
            GridRow {
                Stepper(value: $minimumPages, in: ResearchOptions.minimumPagesRange) {
                    Text("Pages to read: \(minimumPages)").appFont(.body.monospacedDigit())
                }
                .fixedSize()
                .help("The model is asked to read this many pages, and the research opens top results to reach it, as --min-pages.")
                Stepper(value: $stepTimeout, in: ResearchOptions.stepTimeoutMinutesRange) {
                    Text("Step time limit: \(stepTimeout) min").appFont(.body.monospacedDigit())
                }
                .fixedSize()
                .help("A step that takes longer is asked again without reasoning, as --step-timeout.")
            }
            GridRow {
                Stepper(value: $thinkingLimit, in: ResearchOptions.thinkingMinutesRange) {
                    Text("Thinking time limit: \(thinkingLimit) min").appFont(.body.monospacedDigit())
                }
                .fixedSize()
                .help("A step with reasoning on that takes longer is asked again without reasoning, which stays off for the rest of the question, as --thinking-limit.")
            }
            GridRow {
                Toggle("Open top results when too few pages are read", isOn: $autoOpenPages)
                    .help("As --auto-open.")
                Toggle("Ask the model to search, read and look wider", isOn: $nudges)
                    .help("Asks once each when the model answers too early, as --nudges.")
            }
            GridRow {
                Toggle("Rewrite answers that cite unread pages", isOn: $rewrite)
                    .help("As --rewrite.")
                Button("Restore Defaults", action: restoreDefaultOptions)
                    .buttonStyle(.link)
            }
        }
    }

    private func restoreDefaultOptions() {
        let defaults = ResearchOptions()
        maxSteps = defaults.maxSteps
        pageCharacters = defaults.pageSliceCharacters
        showThinking = true
        thinking = "auto"
        maxTokens = 0
        contextCharacters = 0
        searchResults = defaults.searchResults
        toolCalls = defaults.maxToolCallsPerTurn
        minimumPages = defaults.minimumPagesRead
        autoOpenPages = defaults.autoOpenPages
        nudges = defaults.nudges
        rewrite = defaults.reviseUnreadCitations
        stepTimeout = ResearchOptions.defaultStepTimeoutMinutes
        thinkingLimit = ResearchOptions.defaultThinkingMinutes
    }

    private var canAsk: Bool {
        research.servicesReady && !research.run.isRunning
            && !selectedModel.isEmpty
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        guard canAsk else { return }
        let settings = ResearchRunSettings(
            model: selectedModel,
            showThinking: showThinking,
            maxSteps: maxSteps,
            pageCharacters: pageCharacters,
            thinking: thinking == "on" ? true : thinking == "off" ? false : nil,
            maxTokensLimit: maxTokens > 0 ? maxTokens : nil,
            contextCharacters: contextCharacters > 0 ? contextCharacters : nil,
            searchResults: searchResults,
            toolCallsPerTurn: toolCalls,
            minimumPages: minimumPages,
            autoOpenPages: autoOpenPages,
            nudges: nudges,
            reviseUnreadCitations: rewrite,
            stepTimeoutMinutes: stepTimeout,
            thinkingMinutes: thinkingLimit)
        let question = question
        showsProgress = true
        Task { await research.ask(question, settings: settings) }
    }

    /// Keeps the picked model when the server still lists it; otherwise
    /// prefers the fast Gemma 4 E4B.
    private func pickModelIfNeeded() {
        let ids = research.server.models.map(\.id)
        guard !ids.isEmpty, !ids.contains(selectedModel) else { return }
        selectedModel = ids.first { $0.contains("e4b") } ?? ids[0]
    }

    // MARK: - Progress and answer

    @ViewBuilder
    private func results(proxy: ScrollViewProxy) -> some View {
        let run = research.run
        if run.phase == .idle && research.shownReport == nil {
            Text("Each search, each page the model reads, and its thinking appear here while it works. The answer follows with numbered sources you can check.")
                .appFont(.callout)
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
        if research.run.isRunning || research.selectedReportID == nil {
            return research.run.steps.isEmpty
                ? (research.shownReport?.steps ?? []) : research.run.steps
        }
        return research.shownReport?.steps ?? []
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
                            .appFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Progress").appFont(.headline)
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
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(shownSteps) { step in
                    if step.kind != .thinking || showThinking {
                        ResearchStepRow(step: step)
                    }
                }
            }
            if research.run.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working").appFont(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var progressClock: some View {
        if research.run.isRunning, let started = research.run.startedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text(ResearchText.duration(context.date.timeIntervalSince(started)))
                    .appFont(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if research.run.phase == .stopped {
            Text("Stopped").appFont(.caption).foregroundStyle(.secondary)
        } else if let report = research.shownReport {
            Text("\(report.endedEarly == nil ? "Finished" : "Ended early") in \(ResearchText.duration(report.durationSeconds))")
                .appFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func answerCard(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answer").appFont(.headline)
            switch research.run.phase {
            case .running:
                Text(research.run.question).appFont(.headline)
                Text("The answer appears here when the model is done.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message) where research.selectedReportID == nil:
                Label {
                    Text(message).appFont(.callout).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                // What was read before the error is saved and shown.
                if let report = research.run.report {
                    reportView(report, proxy: proxy)
                }
            case .stopped where research.selectedReportID == nil:
                if let report = research.run.report {
                    reportView(report, proxy: proxy)
                } else {
                    Text("Stopped before an answer. Nothing was saved.")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
            default:
                if let report = research.shownReport {
                    reportView(report, proxy: proxy)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func reportView(_ report: SavedResearchReport, proxy: ScrollViewProxy) -> some View {
        ResearchReportView(
            report: report,
            markdownURL: research.reports.markdownURL(for: report),
            saveError: report.id == research.run.report?.id ? research.run.saveError : nil,
            proxy: proxy)
    }

    private var cardBackground: AnyShapeStyle {
        TUFFMacTheme.surfaceStyle(reduceTransparency: reduceTransparency)
    }
}

// MARK: - Services

private struct ResearchServicesCard: View {
    let model: AppModel
    let research: ResearchWorkspace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            serverRow
            Divider()
            sandboxRow
            Divider()
            HStack(spacing: 12) {
                if research.anyServiceOn {
                    Button("Stop Both") { Task { await research.stopServices() } }
                        .disabled(research.server.state.isBusy || research.sandbox.state.isBusy)
                } else {
                    Button("Start Both") { Task { await research.startServices() } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Run Safety Check") { Task { await research.sandbox.runSelfTest() } }
                    .disabled(research.sandbox.state != .ready || research.sandbox.isRunningSelfTest)
                    .help("Checks that the sandbox cannot reach this Mac or your local network, and can still reach the web.")
                if research.sandbox.isRunningSelfTest {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if research.sandbox.repository == nil {
                    Button("Choose TUFF Folder…", action: chooseRepository)
                }
            }
            if let result = research.sandbox.selfTest {
                ResearchSelfTestView(result: result)
            }
        }
        .padding(18)
        .background(
            TUFFMacTheme.surfaceStyle(reduceTransparency: reduceTransparency),
            in: RoundedRectangle(cornerRadius: 16))
    }

    private var serverRow: some View {
        let server = research.server
        return ResearchServiceRow(
            title: "Model server",
            systemImage: "desktopcomputer",
            state: ServiceDisplay(server.state),
            detail: serverDetail,
            isOn: server.state != .off,
            isBusy: server.state.isBusy,
            toggle: { on in
                Task {
                    if on { await server.start() } else { await server.stop() }
                }
            })
    }

    private var serverDetail: String {
        let server = research.server
        switch server.state {
        case .failed(let message):
            return message
        case .starting:
            return "Starting on 127.0.0.1:\(server.port)…"
        case .stopping:
            return "Stopping…"
        case .ready:
            var text = "Ready on 127.0.0.1:\(server.port), only this Mac can reach it. "
            switch server.owner {
            case .backgroundAPI:
                text += "This is the Background API from the Server screen"
                text += server.backgroundAPIWasOn
                    ? "; it was already on, and stopping it here turns it off."
                    : "; stopping it here turns it off again."
            case .app:
                text += server.adoptedFromLastRun
                    ? "Left running when TUFF last closed unexpectedly; it stops when TUFF quits."
                    : "Started by this screen; it stops when TUFF quits."
            case .outside: text += "Started outside TUFF."
            case .none: break
            }
            if model.loadState.isReady {
                text += " The chat model is loaded too and shares memory; unload it from the Model menu if research is slow."
            }
            return text
        case .off:
            return server.canStart
                ? "Runs the model on this Mac. Only this Mac can reach it (127.0.0.1:\(server.port))."
                : "This build cannot start a server. Build everything with `swift build -c release`."
        }
    }

    private var sandboxRow: some View {
        let sandbox = research.sandbox
        return ResearchServiceRow(
            title: "Web sandbox",
            systemImage: "shippingbox.and.arrow.backward",
            state: ServiceDisplay(sandbox.state, protection: sandbox.protection),
            detail: sandboxDetail,
            isOn: sandbox.state != .off,
            isBusy: sandbox.state.isBusy,
            toggle: { on in
                Task {
                    if on { await sandbox.start() } else { await sandbox.stop() }
                }
            })
    }

    private var sandboxDetail: String {
        let sandbox = research.sandbox
        switch sandbox.state {
        case .failed(let message):
            return message
        case .preparing:
            return "Building the sandbox image. The first time takes a few minutes."
        case .starting:
            return "Starting a fresh Linux VM…"
        case .stopping:
            return "Stopping the VM…"
        case .ready:
            let leftOver = sandbox.adoptedFromLastRun
                ? " It was left running when TUFF last closed unexpectedly; it stops when TUFF quits." : ""
            switch sandbox.protection {
            case .verified:
                return "Ready on 127.0.0.1:9000, with no Mac folders. Checked: its firewall is on and "
                    + "the web server runs without privileges. It can reach public web addresses, "
                    + "and on this Mac only the DNS port when it uses the Mac's DNS." + leftOver
            case .checking, .unknown:
                return "Checking the sandbox's firewall and privileges…" + leftOver
            case .notVerified(let message):
                return "Not verified: " + message + " Questions stay off until the check passes."
            }
        case .off:
            if sandbox.repository == nil {
                return "Choose your TUFF folder so the app can find the web sandbox."
            }
            return "A fresh Linux VM in Apple container fetches pages. It cannot see your files."
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the TUFF folder you built this app from. TUFF runs that folder's "
            + "Scripts/research_sandbox.sh to build and start the sandbox, so choose only your own checkout."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            research.sandbox.chooseRepository(url)
        }
    }
}

private struct ServiceDisplay: Equatable {
    let label: String
    let color: Color

    init(_ state: ResearchModelServerController.State) {
        switch state {
        case .off: self.init("Off", .secondary)
        case .starting: self.init("Starting", .orange)
        case .stopping: self.init("Stopping", .orange)
        case .ready: self.init("Ready", .green)
        case .failed: self.init("Problem", .red)
        }
    }

    init(_ state: ResearchSandboxController.State,
         protection: ResearchSandboxController.Protection) {
        if state == .ready {
            switch protection {
            case .verified: self.init("Ready", .green)
            case .checking, .unknown: self.init("Checking", .orange)
            case .notVerified: self.init("Not verified", .red)
            }
            return
        }
        switch state {
        case .off: self.init("Off", .secondary)
        case .preparing: self.init("Preparing", .orange)
        case .starting: self.init("Starting", .orange)
        case .stopping: self.init("Stopping", .orange)
        case .ready: self.init("Ready", .green)
        case .failed: self.init("Problem", .red)
        }
    }

    fileprivate init(_ label: String, _ color: Color) {
        self.label = label
        self.color = color
    }
}

private struct ResearchServiceRow: View {
    let title: String
    let systemImage: String
    let state: ServiceDisplay
    let detail: String
    let isOn: Bool
    let isBusy: Bool
    let toggle: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .appFont(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).appFont(.headline)
                    Text(state.label)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(state.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(state.color.opacity(0.14), in: Capsule())
                    if isBusy { ProgressView().controlSize(.small) }
                }
                Text(detail)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: { toggle($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isBusy)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ResearchSelfTestView: View {
    let result: ResearchSelfTestResult
    @State private var showsChecks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsChecks.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsChecks ? 90 : 0))
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Label(result.passed ? "All safety checks passed" : "Some safety checks failed",
                          systemImage: result.passed ? "checkmark.shield" : "exclamationmark.shield")
                        .appFont(.callout.weight(.semibold))
                        .foregroundStyle(result.passed ? Color.green : Color.red)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsChecks ? "Hide the checks" : "Show the checks")
            if showsChecks {
                ForEach(result.checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: check.outcome))
                            .foregroundStyle(color(for: check.outcome))
                        Text(check.text)
                            .appFont(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !result.summary.isEmpty {
                    Text(result.summary).appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func symbol(for outcome: ResearchSelfTestCheck.Outcome) -> String {
        switch outcome {
        case .passed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .warning: "exclamationmark.circle"
        }
    }

    private func color(for outcome: ResearchSelfTestCheck.Outcome) -> Color {
        switch outcome {
        case .passed: .green
        case .failed: .red
        case .warning: .orange
        }
    }
}

// MARK: - Steps

private struct ResearchStepRow: View {
    let step: ResearchStep
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ResearchText.duration(step.elapsed))
                .appFont(.caption2.monospacedDigit())
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
            Text(step.text).appFont(.callout.weight(.semibold))
        case .thinking:
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(step.text)
                    .appFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text("Thinking").appFont(.callout).foregroundStyle(.secondary)
            }
        case .searching:
            Text("Searching \(Text(step.text).font(.callout.monospaced()))")
                .appFont(.callout)
                .textSelection(.enabled)
        case .reading:
            Text("Reading \(Text(step.text).font(.callout.monospaced()))")
                .appFont(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        case .failed:
            Text(step.text)
                .appFont(.callout)
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
        case .turn: TUFFMacTheme.accentColor
        case .thinking: .secondary
        case .searching: TUFFMacTheme.accentColor
        case .reading: .green
        case .failed: .orange
        }
    }
}

// MARK: - Report

private struct ResearchReportView: View {
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
                .appFont(.title3.weight(.semibold))
                .textSelection(.enabled)
            if let reason = report.endedEarly {
                Label {
                    Text("This research ended early: \(reason). It has no answer; the pages read so far are listed below.")
                        .appFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } else if report.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text("The model stopped without writing an answer. This usually means it used up its token budget while thinking. Try again, or use a faster model such as Qwen3.6 35B-A3B.")
                        .appFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Text(ResearchAnswerFormatter.attributed(
                report.answer, sourceNumbers: Set(report.sources.map(\.number))))
                .appFont(.body)
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
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            if report.unverifiedFigureCount > 0 {
                Text("\(report.unverifiedFigureCount) \(report.unverifiedFigureCount == 1 ? "point" : "points") (figures, dates or names) could not be matched to the pages they cite. The saved report lists them under Figure check.")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            if report.budgetExhausted {
                Text("The research ran out of steps, so this answer may be incomplete.")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            if report.stoppedRepeatedSearches {
                Text("The research stopped early because the model kept repeating searches it had already run, so this answer may be incomplete.")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            if report.sources.isEmpty
                && !report.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No web page was read for this answer, so it comes from the model's memory or search previews and has no sources to check.")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            if report.answerCutOff {
                Text("The answer stopped at the model's length limit, so its end may be missing.")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            if !report.sources.isEmpty {
                Text("Sources").appFont(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.sources) { source in
                        sourceRow(source).id("research-source-\(source.number)")
                    }
                }
            }
            if !report.searchQueries.isEmpty {
                Text("Searches").appFont(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(report.searchQueries.enumerated()), id: \.offset) { _, query in
                        Label(query, systemImage: "magnifyingglass")
                            .appFont(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if report.searchQueries.count == 1 {
                    Text("Only one search was run, so other sources may have been missed.")
                        .appFont(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Label("Written from web pages by a local model (\(report.model)). Check the sources before you rely on it.",
                  systemImage: "info.circle")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
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
                        .appFont(.caption)
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

    private func sourceRow(_ source: SavedResearchReport.Source) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(source.number)")
                .appFont(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(TUFFMacTheme.accentColor)
                .frame(minWidth: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title.isEmpty ? source.host : source.title)
                    .appFont(.callout.weight(.medium))
                    .textSelection(.enabled)
                Text(source.host)
                    .appFont(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open…") { sourceToOpen = source }
                .disabled(source.webURL == nil)
        }
        .padding(8)
        .background(
            highlighted == source.number
                ? TUFFMacTheme.accentColor.opacity(0.14) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8))
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
