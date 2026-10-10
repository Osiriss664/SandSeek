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
    /// Minutes a step with reasoning on may take, as `--thinking-limit`.
    public var thinkingMinutes: Int

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
                stepTimeoutMinutes: Int = ResearchOptions.defaultStepTimeoutMinutes,
                thinkingMinutes: Int = ResearchOptions.defaultThinkingMinutes) {
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
        self.thinkingMinutes = thinkingMinutes
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
        options.thinkingMinutes = thinkingMinutes.clamped(to: ResearchOptions.thinkingMinutesRange)
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

/// Holds the Mac awake while a run is going. The engine lets the Mac sleep
/// when idle, and a run that sleeps mid-way slows down or loses its
/// connection. Only idle system sleep is prevented; the display may sleep.
public protocol ResearchWakeAssertion: Sendable {
    /// Starts holding the Mac awake. Give the token back to `end`.
    func begin(reason: String) -> UUID
    func end(_ token: UUID)
}

/// `ProcessInfo` activities, one per token.
public final class ProcessInfoWakeAssertion: ResearchWakeAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var activities: [UUID: any NSObjectProtocol] = [:]

    public init() {}

    public func begin(reason: String) -> UUID {
        let token = UUID()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        lock.lock()
        activities[token] = activity
        lock.unlock()
        return token
    }

    public func end(_ token: UUID) {
        lock.lock()
        let activity = activities.removeValue(forKey: token)
        lock.unlock()
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
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
    private let wake: any ResearchWakeAssertion
    private var task: Task<Void, Never>?
    private var runID = UUID()
    /// The step that says the run was stopped, until the run has wound down
    /// and it is known whether anything was saved.
    private var stoppedStep: Int?

    public init(store: ResearchReportStore,
                transport: (any ResearchHTTPTransport)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                wake: any ResearchWakeAssertion = ProcessInfoWakeAssertion()) {
        self.store = store
        self.transport = transport
        self.now = now
        self.wake = wake
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
        stoppedStep = nil
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
        // Held from here to the end of the run, however it ends: the run
        // below catches every error, so the end is always reached.
        let wake = self.wake
        let wakeToken = wake.begin(reason: "Web research run")
        task = Task { [weak self] in
            let outcome: Result<ResearchReport, any Error>
            do {
                outcome = .success(try await agent.run(question: question))
            } catch {
                outcome = .failure(error)
            }
            wake.end(wakeToken)
            continuation.finish()
            await listener.value
            self?.finish(outcome, runID: id, started: started, model: settings.model)
        }
    }

    /// Stops the run. Its model request is cancelled, which closes the
    /// connection, and TUFF stops generating the reply. The run then winds
    /// down, and `finish` saves what it had read, if anything.
    public func stop() {
        guard isRunning else { return }
        task?.cancel()
        append(.failed, "Stopped.", started: startedAt ?? now())
        stoppedStep = steps.count - 1
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
        stoppedStep = nil
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
            append(.turn, "No page read yet; asking it to read pages", started: started)
        case .askingToSearchMore:
            append(.turn, "Answered from one search or page; asking it to look wider", started: started)
        case .openingTopResults:
            append(.turn, "Few or no pages read; opening top search results", started: started)
        case .repeatedSearchRefused(let query):
            append(.searching, "Repeated search refused: \(query)", started: started)
        case .repeatedPageRefused(let url):
            append(.reading, "Repeated page refused: \(url)", started: started)
        case .shortenedOlderResults:
            append(.turn, "Shortened older results to fit the model's context", started: started)
        case .retryingAfterTimeout:
            append(.turn, "Step took too long; asking again without thinking", started: started)
        case .retryingAfterTimeoutShorter:
            append(.turn, "Step took too long; shortening older results and asking once more",
                   started: started)
        case .continuingAfterCutOff:
            append(.turn, "Step ran out of room while thinking; continuing the research",
                   started: started)
        case .revisingUnreadCitations:
            append(.turn, "Answer cites pages it never read; asking for a rewrite", started: started)
        case .askingForCitations:
            append(.turn, "Answer lacks source numbers; asking for citations",
                   started: started)
        case .askingForAnswerLanguage:
            append(.turn, "Answer is not in the language asked for; asking for a rewrite",
                   started: started)
        case .continuingCutOffAnswer:
            append(.turn, "Answer hit the token limit; asking it to continue", started: started)
        case .keepingCutOffAnswerNoRoom:
            append(.turn, "Answer hit the token limit; the request to continue would not fit, keeping the cut-off answer",
                   started: started)
        case .droppingRestartedContinuation:
            append(.turn, "The continuation started the answer over; dropping it and keeping the cut-off answer",
                   started: started)
        case .stepSize:
            // A measurement for the command line's progress; not worth a line per step here.
            break
        case .retryingAfterModelError:
            append(.turn, "Model error while thinking; asking again without thinking",
                   started: started)
        case .retryingAfterModelErrorAgain:
            append(.turn, "Model error; asking once more", started: started)
        case .stoppingRepeatedSearches:
            append(.turn, "Only repeated searches or pages; stopping and asking for the answer",
                   started: started)
        case .answerHadToolCalls:
            append(.turn, "The model tried to call a tool; telling it the tools are closed",
                   started: started)
        case .unverifiedFigures(let count):
            append(.turn, "\(count) \(count == 1 ? "point" : "points") could not be matched to the pages they cite",
                   started: started)
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
        // A stopped run still ends here, so what it read can be saved.
        guard runID == self.runID, isRunning || phase == .stopped else { return }
        task = nil
        let stopped = phase == .stopped
        switch outcome {
        case .success(let result):
            // A run that finished while Stop was cancelling it stays stopped.
            guard !stopped else {
                replaceStoppedStep("Stopped. Nothing was saved.")
                return
            }
            save(result, started: started, model: model)
            phase = .finished
        case .failure(let error):
            guard let ended = error as? ResearchRunEndedEarly,
                  !ended.partial.sources.isEmpty || !ended.partial.searchQueries.isEmpty else {
                if stopped {
                    replaceStoppedStep("Stopped. Nothing was saved.")
                } else {
                    phase = .failed(ResearchText.terminalSafe(String(describing: error)))
                }
                return
            }
            // The pages and searches so far are kept, with the reason and no answer.
            save(ended.partial, started: started, model: model)
            if stopped {
                replaceStoppedStep("Stopped. Saved what was read so far.")
            } else {
                append(.failed, "Failed: \(ended.reason). Saved what was read so far.",
                       started: started)
                phase = .failed(ResearchText.terminalSafe(ended.reason))
            }
        }
    }

    private func save(_ result: ResearchReport, started: Date, model: String) {
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
    }

    private func replaceStoppedStep(_ text: String) {
        guard let index = stoppedStep, steps.indices.contains(index) else { return }
        let old = steps[index]
        steps[index] = ResearchStep(
            id: old.id, kind: old.kind, text: ResearchText.terminalSafe(text), elapsed: old.elapsed)
    }
}
