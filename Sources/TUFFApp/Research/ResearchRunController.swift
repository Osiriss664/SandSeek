import Foundation
import Observation
import TUFFResearchCore

public struct ResearchRunSettings: Equatable, Sendable {
    public var model: String
    /// Turns reasoning on and shows it in the progress list, as
    /// `tuff research --show-thinking` does.
    public var showThinking: Bool
    public var maxSteps: Int
    public var pageCharacters: Int

    public init(model: String,
                showThinking: Bool = true,
                maxSteps: Int = 8,
                pageCharacters: Int = 3_000) {
        self.model = model
        self.showThinking = showThinking
        self.maxSteps = maxSteps
        self.pageCharacters = pageCharacters
    }

    /// Reasoning shares the token limit with the answer and tool calls.
    /// Larger models such as Gemma 4 26B can think for more than 4,096
    /// tokens on a long research turn, which cut the turn off with no answer.
    var maxTokens: Int { showThinking ? 8_192 : 1_024 }
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
    private let transport: any ResearchHTTPTransport
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var runID = UUID()

    public init(store: ResearchReportStore,
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(),
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

        var options = ResearchOptions()
        options.maxSteps = settings.maxSteps
        options.pageSliceCharacters = settings.pageCharacters
        let (events, continuation) = AsyncStream<ResearchEvent>.makeStream()
        let agent = ResearchAgent(
            chat: ResearchChatClient(
                serverURL: serverURL,
                model: settings.model,
                maxTokens: settings.maxTokens,
                enableThinking: settings.showThinking ? true : nil,
                transport: transport),
            sandbox: ResearchSandboxClient(baseURL: sandboxURL, transport: transport),
            options: options,
            onEvent: { continuation.yield($0) })

        let maxSteps = settings.maxSteps
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
