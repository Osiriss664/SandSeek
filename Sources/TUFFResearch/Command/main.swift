import Foundation
import TUFFResearchCore

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Progress lines carry text from the web and the model, so control
/// characters are removed before they reach the terminal.
private func writeProgress(_ text: String) {
    writeError(ResearchText.terminalSafe(text))
}

let arguments: ResearchArguments
do {
    arguments = try ResearchArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    writeError("error: \(error)")
    writeError("")
    writeError(ResearchArguments.usage)
    exit(2)
}
if arguments.showHelp {
    print(ResearchArguments.usage)
    exit(0)
}

// The replay needs no model, sandbox or question: it only reads one file.
if let path = arguments.replayFiguresPath {
    do {
        print(ResearchFigureReplay.render(try ResearchSavedPages.load(from: path)))
        exit(0)
    } catch {
        writeProgress("error: cannot replay \(path): \(error)")
        exit(1)
    }
}

// Refuse before any research runs, so a long run never ends in a lost report.
if let path = arguments.outputPath, FileManager.default.fileExists(atPath: path) {
    writeError("error: \(path) already exists; choose a new --output file")
    exit(2)
}
if let path = arguments.savePagesPath, FileManager.default.fileExists(atPath: path) {
    writeError("error: \(path) already exists; choose a new --save-pages file")
    exit(2)
}

// The step timeout is for the model. Sandbox calls keep the default, which
// is far above the sandbox's own limits, so a short step timeout cannot cut
// off a slow page fetch.
let transport = URLSessionResearchTransport(
    timeout: TimeInterval(arguments.stepTimeoutMinutes * 60))
let sandboxTransport = URLSessionResearchTransport()
let quiet = arguments.quiet
let showThinking = arguments.showThinking
let agent = ResearchAgent(
    chat: ResearchChatClient(
        serverURL: arguments.serverURL,
        model: arguments.model,
        maxTokens: arguments.maxTokens,
        enableThinking: arguments.enableThinking,
        transport: transport),
    sandbox: ResearchSandboxClient(baseURL: arguments.sandboxURL, transport: sandboxTransport),
    options: arguments.options,
    onEvent: { event in
        guard !quiet else { return }
        switch event {
        case .modelTurn(let step): writeError("[\(step)] thinking…")
        case .reasoning(let text):
            guard showThinking else { return }
            let indented = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    │ \($0)" }.joined(separator: "\n")
            writeProgress(indented)
        case .searching(let query): writeProgress("    searching: \(query)")
        case .reading(let url): writeProgress("    reading: \(ResearchText.url(url))")
        case .toolFailed(let message): writeProgress("    tool error: \(message)")
        case .retryingEmptyAnswer: writeProgress("    no answer yet; asking for a short one")
        case .askingToSearchFirst: writeProgress("    answered without searching; asking it to search")
        case .askingToReadPages: writeProgress("    no page read yet; asking it to read pages")
        case .askingToSearchMore: writeProgress("    answered from one search or page; asking it to look wider")
        case .askingToReadMoreSources: writeProgress("    fewer pages read than the question asks for; asking it to keep reading")
        case .openingTopResults: writeProgress("    few or no pages read; opening top search results")
        case .repeatedSearchRefused(let query): writeProgress("    repeated search refused: \(query)")
        case .repeatedPageRefused(let url): writeProgress("    repeated page refused: \(url)")
        case .shortenedOlderResults: writeProgress("    shortened older results to fit the model's context")
        case .retryingAfterTimeout: writeProgress("    step took too long; asking again without thinking")
        case .retryingAfterTimeoutShorter:
            writeProgress("    step took too long; shortening older results and asking once more")
        case .continuingAfterCutOff: writeProgress("    step ran out of room while thinking; continuing the research")
        case .revisingUnreadCitations: writeProgress("    answer cites pages it never read; asking for a rewrite")
        case .askingForCitations: writeProgress("    answer lacks source numbers; asking for citations")
        case .askingForAnswerLanguage: writeProgress("    answer is not in the language asked for; asking for a rewrite")
        case .continuingCutOffAnswer: writeProgress("    answer hit the token limit; asking it to continue")
        case .keepingCutOffAnswerNoRoom: writeProgress("    answer hit the token limit; the request to continue would not fit the context, keeping the cut-off answer")
        case .droppingRestartedContinuation: writeProgress("    the continuation started the answer over; dropping it and keeping the cut-off answer")
        case .stepSize(let step, let tool, let assistant, let conversation, let budget):
            writeProgress("    step \(step) added \(tool + assistant) characters "
                + "(tool results \(tool), assistant \(assistant)); conversation \(conversation) of \(budget)")
        case .retryingAfterModelError: writeProgress("    model error while thinking; asking again without thinking")
        case .retryingAfterModelErrorAgain: writeProgress("    model error; asking once more")
        case .stoppingRepeatedSearches: writeProgress("    only repeated searches or pages; stopping and asking for the answer")
        case .answerHadToolCalls: writeProgress("    the model tried to call a tool; telling it the tools are closed")
        case .unverifiedFigures(let count): writeProgress("    \(count) \(count == 1 ? "point" : "points") could not be matched to the pages they cite")
        }
    })

/// Prints the report, and writes it to `--output` when that was given.
func deliver(_ report: ResearchReport, outputPath: String?) throws {
    // The answer and source titles come from the model and the web.
    let markdown = ResearchText.terminalSafe(report.markdown)
    print(markdown)
    if let path = outputPath {
        try Data(markdown.utf8).write(
            to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        writeError("report written to \(path)")
    }
}

// The Mac stays awake for the run: a Mac that sleeps mid-run slows the model
// to a crawl or drops its connection. The display may still sleep.
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .idleSystemSleepDisabled], reason: "Web research run")
let outcome: Result<ResearchReport, any Error>
do {
    outcome = .success(try await agent.run(question: arguments.question))
} catch {
    outcome = .failure(error)
}
ProcessInfo.processInfo.endActivity(activity)

switch outcome {
case .success(let report):
    do {
        try deliver(report, outputPath: arguments.outputPath)
        if let path = arguments.savePagesPath, let saved = ResearchSavedPages(report: report) {
            try saved.encoded().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            writeError("pages written to \(path)")
        }
    } catch {
        writeProgress("error: \(error)")
        exit(1)
    }
case .failure(let error):
    writeProgress("error: \(error)")
    // What was read before the error is kept, in the same form as a report.
    if let ended = error as? ResearchRunEndedEarly {
        do {
            try deliver(ended.partial, outputPath: arguments.outputPath)
            writeError("the research ended early; the report has no answer, only what was read")
            if arguments.savePagesPath != nil {
                writeError("no pages were saved: there is no answer to replay")
            }
        } catch {
            writeProgress("error: \(error)")
        }
    }
    exit(1)
}
