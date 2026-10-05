import Foundation
import Observation
import TUFFResearchCore

/// The same settings as the `tuff research` options, with the same
/// defaults and ranges (`ResearchOptions`).
public struct ResearchRunSettings: Equatable, Sendable {
    public var model: String
    /// Turns reasoning on and shows it in the progress list, as
    /// `tuff research --show-thinking` does.
    public var showThinking: Bool
    public var maxSteps: Int
    public var pageCharacters: Int
    /// Reasoning on or off, as `--thinking`; nil leaves it to Show thinking
    /// and otherwise to the model.
    public var thinking: Bool?
    /// Completion tokens per turn, as `--max-tokens`; nil picks by reasoning.
    public var maxTokensLimit: Int?
    /// Fixed prompt budget, as `--context-chars`; nil follows the model.
    public var contextCharacters: Int?
    public var searchResults: Int
    public var toolCallsPerTurn: Int
    public var minimumPages: Int
    public var autoOpenPages: Bool
    public var nudges: Bool
    public var reviseUnreadCitations: Bool
    public var stepTimeoutMinutes: Int

    public init(model: String,
                showThinking: Bool = true,
                maxSteps: Int = 8,
                pageCharacters: Int = 3_000,
                thinking: Bool? = nil,
                maxTokensLimit: Int? = nil,
                contextCharacters: Int? = nil,
                searchResults: Int = ResearchOptions().searchResults,
                toolCallsPerTurn: Int = ResearchOptions().maxToolCallsPerTurn,
                minimumPages: Int = ResearchOptions().minimumPagesRead,
                autoOpenPages: Bool = true,
                nudges: Bool = true,
                reviseUnreadCitations: Bool = true,
                stepTimeoutMinutes: Int = ResearchOptions.defaultStepTimeoutMinutes) {
        self.model = model
        self.showThinking = showThinking
        self.maxSteps = maxSteps
        self.pageCharacters = pageCharacters
        self.thinking = thinking
        self.maxTokensLimit = maxTokensLimit
        self.contextCharacters = contextCharacters
        self.searchResults = searchResults
        self.toolCallsPerTurn = toolCallsPerTurn
        self.minimumPages = minimumPages
        self.autoOpenPages = autoOpenPages
        self.nudges = nudges
        self.reviseUnreadCitations = reviseUnreadCitations
        self.stepTimeoutMinutes = stepTimeoutMinutes
    }

    /// Reasoning as sent to the server: Show thinking turns it on unless it
    /// was turned off, as `--show-thinking` does with `--thinking`.
    var enableThinking: Bool? { thinking ?? (showThinking ? true : nil) }

    /// Reasoning shares the token limit with the answer and tool calls.
    /// Larger models such as Gemma 4 26B can think for more than 4,096
    /// tokens on a long research turn, which cut the turn off with no answer.
    var maxTokens: Int {
        let limit = maxTokensLimit ?? (enableThinking == true ? 8_192 : 2_048)
        return limit.clamped(to: ResearchOptions.maxTokensRange)
    }

    /// The loop options, each clamped to the range the command line accepts.
    var options: ResearchOptions {
        var options = ResearchOptions()
        options.maxSteps = maxSteps.clamped(to: ResearchOptions.maxStepsRange)
        options.pageSliceCharacters = pageCharacters.clamped(
            to: ResearchOptions.pageCharactersRange)
        options.contextBudgetCharacters = contextCharacters?.clamped(
            to: ResearchOptions.contextCharactersRange)
        options.searchResults = searchResults.clamped(to: ResearchOptions.searchResultsRange)
        options.maxToolCallsPerTurn = toolCallsPerTurn.clamped(
            to: ResearchOptions.toolCallsRange)
        options.minimumPagesRead = minimumPages.clamped(to: ResearchOptions.minimumPagesRange)
        options.autoOpenPages = autoOpenPages
        options.nudges = nudges
        options.reviseUnreadCitations = reviseUnreadCitations
        return options
    }

    var stepTimeout: TimeInterval {
        TimeInterval(stepTimeoutMinutes.clamped(to: ResearchOptions.stepTimeoutMinutesRange) * 60)
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Runs one research question at a time with the same loop as `tuff
/// research`, and turns its events into a progress list.
@MainActor @Observable
public final class ResearchRunController {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case finished
        case stopped
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var question = ""
    public private(set) var steps: [ResearchStep] = []
    public private(set) var startedAt: Date?
    /// The report of the last finished run.
    public private(set) var report: SavedResearchReport?
    /// Set when a finished report could not be written to disk.
    public private(set) var saveError: String?

    private let store: ResearchReportStore
    /// Nil makes a transport per run with that run's step timeout.
    private let transport: (any ResearchHTTPTransport)?
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var runID = UUID()

    public init(store: ResearchReportStore,
                transport: (any ResearchHTTPTransport)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    public var isRunning: Bool { phase == .running }

    public func start(question: String,
                      settings: ResearchRunSettings,
                      serverURL: URL,
                      sandboxURL: URL) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !question.isEmpty else { return }
        let id = UUID()
        let started = now()
        runID = id
        self.question = question
        steps = []
        report = nil
        saveError = nil
        startedAt = started
        phase = .running

        let options = settings.options
        // The step timeout is for the model; sandbox calls keep the default,
        // far above the sandbox's own limits.
        let transport = self.transport
            ?? URLSessionResearchTransport(timeout: settings.stepTimeout)
        let sandboxTransport = self.transport ?? URLSessionResearchTransport()
        let (events, continuation) = AsyncStream<ResearchEvent>.makeStream()
        let agent = ResearchAgent(
            chat: ResearchChatClient(
                serverURL: serverURL,
                model: settings.model,
                maxTokens: settings.maxTokens,
                enableThinking: settings.enableThinking,
                transport: transport),
            sandbox: ResearchSandboxClient(baseURL: sandboxURL, transport: sandboxTransport),
            options: options,
            onEvent: { continuation.yield($0) })

        let maxSteps = options.maxSteps
        let listener = Task { [weak self] in
            for await event in events {
                self?.record(event, runID: id, started: started, maxSteps: maxSteps)
            }
        }
        task = Task { [weak self] in
            let outcome: Result<ResearchReport, any Error>
            do {
                outcome = .success(try await agent.run(question: question))
            } catch {
                outcome = .failure(error)
            }
            continuation.finish()
            await listener.value
            self?.finish(outcome, runID: id, started: started, model: settings.model)
        }
    }

    /// Stops waiting for the run. A model reply already being written still
    /// finishes on the server, but nothing more is asked of it.
    public func stop() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        runID = UUID()
        append(.failed, "Stopped. Nothing was saved.", started: startedAt ?? now())
        phase = .stopped
    }

    /// Clears the screen for a new question.
    public func reset() {
        guard !isRunning else { return }
        phase = .idle
        question = ""
        steps = []
        report = nil
        saveError = nil
        startedAt = nil
    }

    private func record(_ event: ResearchEvent, runID: UUID, started: Date, maxSteps: Int) {
        guard runID == self.runID, isRunning else { return }
        switch event {
        case .modelTurn(let step):
            append(.turn, "Step \(step) of \(maxSteps)", started: started)
        case .reasoning(let text):
            append(.thinking, text, started: started)
        case .searching(let query):
            append(.searching, query, started: started)
        case .reading(let url):
            append(.reading, ResearchText.url(url), started: started)
        case .toolFailed(let message):
            append(.failed, message, started: started)
        case .retryingEmptyAnswer:
            append(.turn, "No answer yet; asking for a short one", started: started)
        case .askingToSearchFirst:
            append(.turn, "Answered without searching; asking it to search", started: started)
        case .askingToReadPages:
            append(.turn, "Answered from search previews; asking it to read pages", started: started)
        case .askingToSearchMore:
            append(.turn, "Answered from one search or page; asking it to look wider", started: started)
        case .openingTopResults:
            append(.turn, "Few or no pages read; opening top search results", started: started)
        case .repeatedSearchRefused(let query):
            append(.searching, "Repeated search refused: \(query)", started: started)
        case .shortenedOlderResults:
            append(.turn, "Shortened older results to fit the model's context", started: started)
        case .retryingAfterTimeout:
            append(.turn, "Step took too long; asking again without thinking", started: started)
        case .continuingAfterCutOff:
            append(.turn, "Step ran out of room while thinking; continuing the research",
                   started: started)
        case .revisingUnreadCitations:
            append(.turn, "Answer cites pages it never read; asking for a rewrite", started: started)
        }
    }

    private func append(_ kind: ResearchStep.Kind, _ text: String, started: Date) {
        steps.append(ResearchStep(
            id: steps.count,
            kind: kind,
            text: ResearchText.terminalSafe(text),
            elapsed: max(0, now().timeIntervalSince(started))))
    }

    private func finish(_ outcome: Result<ResearchReport, any Error>,
                        runID: UUID,
                        started: Date,
                        model: String) {
        guard runID == self.runID, isRunning else { return }
        task = nil
        switch outcome {
        case .success(let result):
            let saved = SavedResearchReport(
                report: result,
                model: model,
                createdAt: started,
                durationSeconds: max(0, now().timeIntervalSince(started)),
                steps: steps)
            report = saved
            do {
                try store.save(saved)
            } catch {
                saveError = "The report could not be saved: \(error.localizedDescription)"
            }
            phase = .finished
        case .failure(let error):
            phase = .failed(ResearchText.terminalSafe(String(describing: error)))
        }
    }
}
