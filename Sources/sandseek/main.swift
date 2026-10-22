import Foundation
import SandSeekCore

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Progress lines carry text from the web and the model, so control
/// characters are removed before they reach the terminal.
private func writeProgress(_ text: String) {
    writeError(ResearchText.terminalSafe(text))
}

// The old TUFF_RESEARCH_ names are ignored now. Say so, so that a run is not
// silently measured with the default settings. This never stops the run.
let oldVariablePrefix = "TUFF_RESEARCH_"
for name in ProcessInfo.processInfo.environment.keys.sorted() where name.hasPrefix(oldVariablePrefix) {
    let replacement = "SANDSEEK_" + String(name.dropFirst(oldVariablePrefix.count))
    writeError("warning: \(name) is the old name and is ignored; use \(replacement)")
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
if arguments.showVersion {
    print(SandSeekVersion.text)
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

// The exposure check needs no model, sandbox or question either: it only
// tries this Mac's own network addresses on the two ports.
if arguments.checkExposure {
    // Ollama's usual port gets Ollama's advice (OLLAMA_HOST).
    let serverPort = arguments.serverURL.port ?? 80
    let result = await ResearchExposureCommand.run(
        serverPort: serverPort,
        sandboxPort: arguments.resolvedSandboxURL().port ?? 80,
        serverKind: serverPort == 11_434 ? ResearchServerKind.ollama : nil)
    print(result.text)
    exit(result.exitCode)
}

// The Host header check needs no model, sandbox or question either: it sends
// three read-only GET requests to the model server's model list.
if arguments.checkHostHeader {
    guard let address = ResearchHostHeaderCheck.loopbackAddress(for: arguments.serverURL) else {
        writeError("error: --check-host-header only checks a server on this Mac's loopback address "
            + "(127.0.0.1 or ::1)")
        exit(ResearchHostHeaderCommand.exitBadArguments)
    }
    let hostHeaderPort = arguments.serverURL.port ?? 80
    let hostHeaderAuthorization: String?
    do {
        hostHeaderAuthorization = try arguments.apiKeyFile.map(ResearchAPIKeyFile.authorization(atPath:))
    } catch {
        writeError("error: \(error)")
        exit(ResearchHostHeaderCommand.exitBadArguments)
    }
    // Which path is asked depends on the kind of server: Ollama has its own
    // model list. `auto` asks the server (cheap: one status request); when it
    // is not recognised, port 11434 means Ollama, as for --check-exposure.
    let hostHeaderKind: ResearchServerKind?
    switch arguments.serverType {
    case .tuff: hostHeaderKind = .tuff
    case .llamacpp: hostHeaderKind = .llamacpp
    case .ollama: hostHeaderKind = .ollama
    case .auto:
        let detected = try? await ResearchServerConnection.establish(
            choice: .auto, stream: nil, serverURL: arguments.serverURL,
            transport: URLSessionResearchTransport(timeout: 5))
        hostHeaderKind = detected?.kind ?? (hostHeaderPort == 11_434 ? ResearchServerKind.ollama : nil)
    }
    if hostHeaderKind == .ollama, hostHeaderAuthorization != nil {
        writeError("error: --api-key-file cannot be used with Ollama: it has no key on this Mac, "
            + "and SandSeek sends none to it")
        exit(ResearchHostHeaderCommand.exitBadArguments)
    }
    let result = await ResearchHostHeaderCommand.run(
        port: hostHeaderPort, serverKind: hostHeaderKind,
        authorization: hostHeaderAuthorization, address: address,
        prober: ResearchSocketHTTPProber(address: address))
    print(result.text)
    exit(result.exitCode)
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
// The key of a model server that asks for one. It is read from a file so that
// it is not on the command line, and goes only into the chat requests.
let authorization: String?
do {
    authorization = try arguments.apiKeyFile.map(ResearchAPIKeyFile.authorization(atPath:))
} catch {
    writeError("error: \(error)")
    exit(2)
}
let sandboxTransport = URLSessionResearchTransport()
let quiet = arguments.quiet

// Which server this is decides how it is asked (TUFF, with
// streaming). A server that is not recognised is refused before any research
// runs. A model server that does not answer ends the run with exit code 1, as
// it always did (it is now found before the sandbox check, not after); a
// server that is not recognised is a usage error, exit code 2.
let connection: ResearchServerConnection
do {
    let found = try await ResearchServerConnection.establish(
        choice: arguments.serverType, stream: arguments.stream,
        serverURL: arguments.serverURL, transport: transport)
    // Ollama: the model is checked (installed, local, can call tools) and the
    // context window is chosen before the first question is sent. A key file
    // and a cloud model name are refused here too when the type was found by
    // `auto`.
    if found.kind == .ollama, authorization != nil {
        throw ResearchArgumentError(
            "--api-key-file cannot be used with Ollama: it has no key on this Mac, "
                + "and SandSeek sends none to it")
    }
    if found.kind != .ollama, arguments.contextTokens != nil {
        throw ResearchArgumentError(
            "--context-tokens is only for Ollama; the server at "
                + "\(arguments.serverURL.absoluteString) is \(found.kind.displayName)")
    }
    connection = try await ResearchOllama.prepare(
        found, model: arguments.model, requestedContextTokens: arguments.contextTokens,
        serverURL: arguments.serverURL, transport: transport)
} catch {
    writeProgress("error: \(error)")
    if case ResearchError.modelUnavailable = error { exit(1) }
    // Ollama's /api/show failed on the server's side: not a usage error.
    if case ResearchError.modelRequestFailed = error { exit(1) }
    exit(2)
}
if let warning = connection.warning { writeProgress("warning: \(warning)") }
// Ollama: `think` follows what the model can do (see `ResearchOllama.thinking`).
let enableThinking = ResearchOllama.thinking(
    requested: arguments.enableThinking, connection: connection)
if !quiet { writeProgress(connection.progressLine(enableThinking: enableThinking)) }
if !quiet, let note = ResearchOllama.thinkingNote(
    requested: arguments.enableThinking, model: arguments.model, connection: connection) {
    writeProgress(note)
}
let showThinking = arguments.showThinking
// The context window the server named outside its model list (Ollama's
// `num_ctx`) is the loop's known budget, unless --context-chars fixes one.
let runOptions: ResearchOptions = {
    var options = arguments.options
    options.knownContextTokens = connection.contextTokens
    return options
}()
let agent = ResearchAgent(
    chat: ResearchChatClient(
        serverURL: arguments.serverURL,
        model: arguments.model,
        maxTokens: arguments.maxTokens,
        enableThinking: enableThinking,
        streaming: connection.streaming,
        authorization: authorization,
        kind: connection.kind,
        requestedContextTokens: connection.contextTokens,
        transport: transport),
    sandbox: ResearchSandboxClient(
        baseURL: arguments.resolvedSandboxURL(), transport: sandboxTransport,
        secretFile: ResearchSandboxSecret.defaultFileURL),
    options: runOptions,
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
        case .unseenURLRefused(let url): writeProgress("    unknown address refused: \(url)")
        case .privateAddressRefused(let url): writeProgress("    local network address refused: \(url)")
        case .shortenedOlderResults: writeProgress("    shortened older results to fit the model's context")
        case .retryingAfterTimeout: writeProgress("    step took too long; asking again without thinking")
        case .retryingAfterTimeoutShorter:
            writeProgress("    step took too long; shortening older results and asking once more")
        case .continuingAfterCutOff: writeProgress("    step ran out of room while thinking; continuing the research")
        case .revisingUnreadCitations: writeProgress("    answer cites pages it never read; asking for a rewrite")
        case .rewriteNotKept(let reason): writeProgress("    rewrite not kept: \(reason)")
        case .askingForCitations: writeProgress("    answer lacks source numbers; asking for citations")
        case .askingForAnswerLanguage: writeProgress("    answer is not in the language asked for; asking for a rewrite")
        case .continuingCutOffAnswer: writeProgress("    answer hit the token limit; asking it to continue")
        case .keepingCutOffAnswerNoRoom: writeProgress("    answer hit the token limit; the request to continue would not fit the context, keeping the cut-off answer")
        case .droppingRestartedContinuation: writeProgress("    the continuation started the answer over; dropping it and keeping the cut-off answer")
        case .continuingMidSentenceAnswer: writeProgress("    answer seems to stop mid-sentence; asking it to continue")
        case .droppingRestartedMidSentenceContinuation: writeProgress("    the reply started the answer over; taking the answer as complete")
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
