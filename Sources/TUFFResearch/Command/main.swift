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

// Refuse before any research runs, so a long run never ends in a lost report.
if let path = arguments.outputPath, FileManager.default.fileExists(atPath: path) {
    writeError("error: \(path) already exists; choose a new --output file")
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
        case .askingToReadPages: writeProgress("    answered from search previews; asking it to read pages")
        case .askingToSearchMore: writeProgress("    answered from one search or page; asking it to look wider")
        case .openingTopResults: writeProgress("    few or no pages read; opening top search results")
        case .repeatedSearchRefused(let query): writeProgress("    repeated search refused: \(query)")
        case .repeatedPageRefused(let url): writeProgress("    repeated page refused: \(url)")
        case .shortenedOlderResults: writeProgress("    shortened older results to fit the model's context")
        case .retryingAfterTimeout: writeProgress("    step took too long; asking again without thinking")
        case .continuingAfterCutOff: writeProgress("    step ran out of room while thinking; continuing the research")
        case .revisingUnreadCitations: writeProgress("    answer cites pages it never read; asking for a rewrite")
        case .retryingAfterModelError: writeProgress("    model error while thinking; asking again without thinking")
        case .stoppingRepeatedSearches: writeProgress("    only repeated searches or pages; stopping and asking for the answer")
        }
    })

do {
    let report = try await agent.run(question: arguments.question)
    // The answer and source titles come from the model and the web.
    let markdown = ResearchText.terminalSafe(report.markdown)
    print(markdown)
    if let path = arguments.outputPath {
        try Data(markdown.utf8).write(
            to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        writeError("report written to \(path)")
    }
} catch {
    writeProgress("error: \(error)")
    exit(1)
}
