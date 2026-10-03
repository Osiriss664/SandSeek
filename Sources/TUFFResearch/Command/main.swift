import Foundation
import TUFFResearchCore

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
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

let transport = URLSessionResearchTransport()
let quiet = arguments.quiet
let showThinking = arguments.showThinking
let agent = ResearchAgent(
    chat: ResearchChatClient(
        serverURL: arguments.serverURL,
        model: arguments.model,
        maxTokens: arguments.maxTokens,
        enableThinking: arguments.enableThinking,
        transport: transport),
    sandbox: ResearchSandboxClient(baseURL: arguments.sandboxURL, transport: transport),
    options: arguments.options,
    onEvent: { event in
        guard !quiet else { return }
        switch event {
        case .modelTurn(let step): writeError("[\(step)] thinking…")
        case .reasoning(let text):
            guard showThinking else { return }
            let indented = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    │ \($0)" }.joined(separator: "\n")
            writeError(indented)
        case .searching(let query): writeError("    searching: \(query)")
        case .reading(let url): writeError("    reading: \(url)")
        case .toolFailed(let message): writeError("    tool error: \(message)")
        }
    })

do {
    let report = try await agent.run(question: arguments.question)
    let markdown = report.markdown
    print(markdown)
    if let path = arguments.outputPath {
        try Data(markdown.utf8).write(
            to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        writeError("report written to \(path)")
    }
} catch {
    writeError("error: \(error)")
    exit(1)
}
