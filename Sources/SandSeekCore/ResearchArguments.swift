import Foundation

public struct ResearchArguments: Equatable, Sendable {
    public var question: String = ""
    public var model: String = "default"
    public var serverURL: URL = URL(string: "http://127.0.0.1:8080")!
    /// A file holding the model server's key (`--api-key-file`). The command
    /// reads it and sends it as a Bearer token to the server, which is on
    /// loopback.
    public var apiKeyFile: String?
    /// The sandbox's address. Without `--sandbox`, `sandboxGiven` is false and
    /// the command finds the sandbox through `resolvedSandboxURL` instead
    /// (this is the address of last resort).
    public var sandboxURL: URL = ResearchSandboxFiles.url(port: ResearchSandboxFiles.fallbackPort)
    public var sandboxGiven = false
    /// Which kind of model server `serverURL` is; `auto` asks it.
    public var serverType: ResearchServerChoice = .auto
    /// Whether to read model replies as a stream. Nil is the default for the
    /// server kind: on for TUFF and Ollama, off for llama.cpp (see
    /// `ResearchServerConnection`).
    public var stream: Bool?
    /// `--context-tokens`: the context window an Ollama run asks for
    /// (`num_ctx`). Nil is the default: 32,768, or the model's trained
    /// maximum when that is smaller.
    public var contextTokens: Int?
    public var outputPath: String?
    /// Test aids: write the answer and page texts of a finished run to a new
    /// JSON file, and run the figure check again on such a file, with no
    /// model and no sandbox.
    public var savePagesPath: String?
    public var replayFiguresPath: String?
    /// `--check-exposure`: try this Mac's own network addresses on the model
    /// server's port and the sandbox's port, and report which answered. It
    /// needs no question, model or sandbox, only `--server` and `--sandbox`
    /// for the ports.
    public var checkExposure = false
    public var maxTokens: Int = 2_048
    public var enableThinking: Bool?
    public var showThinking = false
    public var quiet = false
    /// Minutes one model step may take before it is retried without reasoning.
    public var stepTimeoutMinutes = ResearchOptions.defaultStepTimeoutMinutes
    public var showHelp = false
    /// `--version`: print `SandSeekVersion.text` and stop; no question needed.
    public var showVersion = false
    public var options = ResearchOptions()

    /// Where the sandbox is: `--sandbox` when it was given, else the port in
    /// `SANDSEEK_SANDBOX_PORT` (for tests), else the one the sandbox's start
    /// recorded in `folder`, else port 9100.
    public func resolvedSandboxURL(
        folder: URL = ResearchSandboxFiles.defaultFolder,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        sandboxGiven ? sandboxURL
            : ResearchSandboxFiles.sandboxURL(folder: folder, environment: environment)
    }

    public static let usage = """
    usage: sandseek <question> [options]
           sandseek --version

    Researches a question on the web with a local model. Web pages are
    fetched by the sandbox, a small server in an Apple container Linux VM
    (Scripts/research_sandbox.sh start). The model can only search and read
    pages; it cannot run commands or touch files.

    options:
      --model <name>           Model the server should use (default: default,
                               the model selected on the server).
      --server <url>           Model server (default: http://127.0.0.1:8080).
      --server-type tuff|llamacpp|ollama|auto
                               Kind of model server (default auto: the
                               command asks TUFF's /tuff/v1/status and uses
                               TUFF when it answers, else Ollama when its
                               /api/version answers; any other server is
                               refused). A llama.cpp server must be named
                               with llamacpp; it is experimental and gets
                               plain (non-streaming) requests. With tuff the
                               status route is asked too: a server that does not
                               answer at all ends the run (exit code 1), one
                               that answers something else gives a warning.
                               Ollama is experimental. It is used through its
                               own /api/chat, on 127.0.0.1:11434 (--server
                               http://127.0.0.1:11434); --model must name an
                               installed model that can call tools. Ollama
                               cloud models (names ending in :cloud or -cloud)
                               are refused, because the question would leave
                               this Mac. Ollama needs no key, so
                               --api-key-file is refused with it.
      --context-tokens <4096...262144>
                               Context window of an Ollama run (num_ctx), also
                               the budget the research plans its prompts with
                               (default: 32768, or the model's trained maximum
                               when that is smaller). Only for Ollama, whose
                               own default of 4096 tokens is too small. A
                               larger window needs more memory.
      --api-key-file <path>    File with the key of a model server that asks
                               for one (llama-server --api-key-file). The key
                               is sent as a Bearer token to the server, which
                               is on this Mac, and is never printed. Keep the
                               key off the command line: it would show in
                               `ps` and in your shell history.
      --stream on|off          Read each model reply as a stream (default on
                               for TUFF and Ollama). Streaming lets Stop and
                               the time limits make the server stop
                               generating; with off, TUFF finishes an
                               abandoned reply anyway. Not available for
                               llamacpp yet.
      --sandbox <url>          Web sandbox (default: the port the sandbox's start
                               recorded, or SANDSEEK_SANDBOX_PORT if set; else
                               http://127.0.0.1:9100).
      --max-steps <1...100>    Model turns that may use tools (default 8).
      --max-tokens <n>         Completion tokens per model turn, 64...32768
                               (default 2048, or 8192 with reasoning on).
      --page-chars <n>         Page text per read, 500...20000 (default 3000).
      --passages on|off        Let open_page return the passages of a page that
                               best match the question first (BM25, ranked in
                               the sandbox), and the next best ones on a later
                               read, instead of the page from front to back.
                               With it on a read is 2000 characters unless
                               --page-chars says otherwise (default off).
      --context-chars <n>      Prompt budget before old results are shortened,
                               2000...1000000 (default: from the model's
                               context window, or 16000 when not listed).
      --search-results <1...10>
                               Results per search (default 5).
      --tool-calls <1...8>     Tool calls the model may make per turn
                               (default 4).
      --min-pages <1...12>     Pages the research should read; the prompt asks
                               for this many and the loop opens top results
                               to reach it (default 3).
      --auto-open on|off       Let the loop open top results itself when the
                               model reads too few pages (default on).
      --nudges on|off          Ask the model once to search, to open pages, or
                               to look wider when it answers too early
                               (default on).
      --only-seen-urls on|off  Open only addresses that appear verbatim in a
                               search result, a source or the question
                               (default on; off is for measuring the model).
      --page-links on|off      Also open addresses that appear only in the text
                               of a page read, which --only-seen-urls on
                               refuses (default off; on is for comparing).
      --rewrite on|off         Ask once for a rewrite when the answer cites
                               pages that were never read, has figures without
                               a source number, or is in the wrong language
                               (default on).
      --step-timeout <1...60>  Minutes one model step may take before it is
                               retried without reasoning (default 30).
      --thinking-limit <1...60>
                               Minutes a step with reasoning on may take before
                               it is asked again with reasoning off, which then
                               stays off for the run (default 3).
      --thinking on|off        Gemma and Qwen reasoning (default: model's own).
      --show-thinking          Turn reasoning on and print it with the
                               progress. It is not added to the report.
      --output <file.md>       Also write the report to a new file.
      --save-pages <file.json> Test aid: also write the question, the answer,
                               today's date and the text of every page read to
                               a new JSON file, for --replay-figures. Only
                               finished reports are saved.
      --replay-figures <file.json>
                               Test aid: run the figure check again on a file
                               from --save-pages and print its section.
                               Needs no question, server or sandbox.
      --quiet                  Do not print progress to standard error.
      --version                Print the version and exit.
      --check-exposure         Check whether the model server (the port of
                               --server) or the sandbox (the port of
                               --sandbox) can be reached from the network:
                               the command tries a plain TCP connect, with no
                               data sent, to each of this Mac's own non-loopback
                               addresses. Needs no question. Exit code 0 when
                               every address refused the connection, 2 for
                               bad arguments, 3 when something answered on
                               the network, 4 when the model server does not
                               answer on this Mac at all, 5 when some address
                               neither accepted nor refused (a timeout or a
                               block, for example macOS Local Network
                               privacy); 4 and 5 mean "cannot tell".
                               Start llama-server with --host 127.0.0.1 if it
                               answers; TUFF listens on 127.0.0.1 only. Start
                               Ollama with OLLAMA_HOST=127.0.0.1:11434 (the
                               advice for Ollama is given when the port is
                               11434).
    """

    public init() {}

    /// The environment variable that overrides the `preserve_thinking` rule,
    /// for measuring the prompt cache: `on`, `off` or `auto` (the default).
    /// Not an option and not shown in the app.
    public static let preserveThinkingVariable = "SANDSEEK_PRESERVE_THINKING"

    /// The environment variable that chooses the markers around web text, for
    /// comparing them on a Mac: `fixed` (the default, the same in every run)
    /// or `nonce` (a random code per run). Not an option and not shown in the app.
    public static let markersVariable = "SANDSEEK_MARKERS"

    /// The environment variable that names a file for the messages of the
    /// first request for the answer, for measuring what the model read.
    /// Off when not set. Not an option and not shown in the app.
    public static let dumpAnswerRequestVariable = "SANDSEEK_DUMP_ANSWER_REQUEST"

    public static func parse(_ arguments: [String],
                             environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResearchArguments {
        var parsed = ResearchArguments()
        if let text = environment[preserveThinkingVariable], !text.isEmpty {
            guard let mode = ResearchPreserveThinking(
                rawValue: text.lowercased()) else {
                throw ResearchArgumentError(
                    "\(preserveThinkingVariable) must be on, off or auto")
            }
            parsed.options.preserveThinking = mode
        }
        if let text = environment[markersVariable], !text.isEmpty {
            guard let mode = ResearchMarkerMode(rawValue: text.lowercased()) else {
                throw ResearchArgumentError("\(markersVariable) must be fixed or nonce")
            }
            parsed.options.markers = mode
        }
        if let path = environment[dumpAnswerRequestVariable], !path.isEmpty {
            parsed.options.dumpAnswerRequestPath = path
        }
        var words: [String] = []
        var index = 0
        var maxTokensGiven = false
        // The first option other than the replay's own, which it cannot take.
        var runOption: String?
        // The same for --check-exposure, which takes only --server, --sandbox and --quiet.
        var exposureOption: String?
        func value(_ flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw ResearchArgumentError("missing value for \(flag)")
            }
            index += 1
            return arguments[index]
        }
        func integer(_ flag: String, _ range: ClosedRange<Int>) throws -> Int {
            let text = try value(flag)
            guard let number = Int(text), range.contains(number) else {
                throw ResearchArgumentError(
                    "\(flag) must be between \(range.lowerBound) and \(range.upperBound)")
            }
            return number
        }
        func onOff(_ flag: String) throws -> Bool {
            switch try value(flag) {
            case "on": return true
            case "off": return false
            default: throw ResearchArgumentError("\(flag) must be on or off")
            }
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-"), argument != "--", runOption == nil,
               !["--help", "-h", "--version", "--replay-figures", "--quiet"].contains(argument) {
                runOption = argument
            }
            if argument.hasPrefix("-"), argument != "--", exposureOption == nil,
               !["--help", "-h", "--version", "--check-exposure", "--server", "--sandbox", "--quiet"].contains(argument) {
                exposureOption = argument
            }
            switch argument {
            case "--help", "-h":
                parsed.showHelp = true
            case "--version":
                parsed.showVersion = true
            case "--model":
                parsed.model = try value(argument)
            case "--server":
                parsed.serverURL = try ResearchEndpoint.loopbackURL(try value(argument), flag: argument)
            case "--server-type":
                let text = try value(argument)
                guard let choice = ResearchServerChoice(rawValue: text) else {
                    throw ResearchArgumentError(
                        "--server-type must be tuff, llamacpp, ollama or auto")
                }
                parsed.serverType = choice
            case "--api-key-file":
                parsed.apiKeyFile = try value(argument)
            case "--context-tokens":
                parsed.contextTokens = try integer(argument, ResearchOllama.contextTokensRange)
            case "--stream":
                parsed.stream = try onOff(argument)
            case "--sandbox":
                parsed.sandboxURL = try ResearchEndpoint.loopbackURL(try value(argument), flag: argument)
                parsed.sandboxGiven = true
            case "--max-steps":
                parsed.options.maxSteps = try integer(argument, ResearchOptions.maxStepsRange)
            case "--max-tokens":
                parsed.maxTokens = try integer(argument, ResearchOptions.maxTokensRange)
                maxTokensGiven = true
            case "--page-chars":
                let characters = try integer(argument, ResearchOptions.pageCharactersRange)
                parsed.options.pageSliceCharacters = characters
                parsed.options.passageSliceCharacters = characters
            case "--passages":
                parsed.options.passages = try onOff(argument)
            case "--context-chars":
                parsed.options.contextBudgetCharacters = try integer(
                    argument, ResearchOptions.contextCharactersRange)
            case "--search-results":
                parsed.options.searchResults = try integer(
                    argument, ResearchOptions.searchResultsRange)
            case "--tool-calls":
                parsed.options.maxToolCallsPerTurn = try integer(
                    argument, ResearchOptions.toolCallsRange)
            case "--min-pages":
                parsed.options.minimumPagesRead = try integer(
                    argument, ResearchOptions.minimumPagesRange)
            case "--auto-open":
                parsed.options.autoOpenPages = try onOff(argument)
            case "--nudges":
                parsed.options.nudges = try onOff(argument)
            case "--only-seen-urls":
                parsed.options.onlySeenURLs = try onOff(argument)
            case "--page-links":
                parsed.options.pageLinks = try onOff(argument)
            case "--rewrite":
                parsed.options.reviseUnreadCitations = try onOff(argument)
            case "--step-timeout":
                parsed.stepTimeoutMinutes = try integer(
                    argument, ResearchOptions.stepTimeoutMinutesRange)
            case "--thinking-limit":
                parsed.options.thinkingMinutes = try integer(
                    argument, ResearchOptions.thinkingMinutesRange)
            case "--thinking":
                parsed.enableThinking = try onOff(argument)
            case "--show-thinking":
                parsed.showThinking = true
            case "--output":
                parsed.outputPath = try value(argument)
            case "--save-pages":
                parsed.savePagesPath = try value(argument)
                parsed.options.keepPageTexts = true
            case "--replay-figures":
                parsed.replayFiguresPath = try value(argument)
            case "--quiet":
                parsed.quiet = true
            case "--check-exposure":
                parsed.checkExposure = true
            case "--":
                words += arguments[(index + 1)...]
                index = arguments.count
                continue
            default:
                guard !argument.hasPrefix("-") else {
                    throw ResearchArgumentError("unknown option \(argument)")
                }
                words.append(argument)
            }
            index += 1
        }
        if parsed.showThinking {
            parsed.enableThinking = parsed.enableThinking ?? true
        }
        // Reasoning shares the token limit with the answer and tool calls; a
        // slow model can think for several thousand tokens before answering.
        if parsed.enableThinking == true, !maxTokensGiven {
            parsed.maxTokens = 8_192
        }
        parsed.question = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A replay reads one file; no run, question or output goes with it.
        if parsed.replayFiguresPath != nil, !parsed.showHelp, !parsed.showVersion {
            if let runOption {
                throw ResearchArgumentError("--replay-figures cannot be combined with \(runOption)")
            }
            if !words.isEmpty {
                throw ResearchArgumentError("--replay-figures takes no question")
            }
        }
        // The exposure check looks at two ports; no run goes with it.
        if parsed.checkExposure, !parsed.showHelp, !parsed.showVersion {
            if parsed.replayFiguresPath != nil {
                throw ResearchArgumentError("--check-exposure cannot be combined with --replay-figures")
            }
            if let exposureOption {
                throw ResearchArgumentError("--check-exposure cannot be combined with \(exposureOption)")
            }
            if !words.isEmpty {
                throw ResearchArgumentError("--check-exposure takes no question")
            }
        }
        if let output = parsed.outputPath, let saved = parsed.savePagesPath,
           URL(fileURLWithPath: output).standardizedFileURL
               == URL(fileURLWithPath: saved).standardizedFileURL {
            throw ResearchArgumentError("--output and --save-pages must name different files")
        }
        if parsed.serverType == .llamacpp, parsed.stream == true, !parsed.showHelp, !parsed.showVersion {
            throw ResearchArgumentError(ResearchServerConnection.streamingNeedsConnectorMessage)
        }
        // Ollama has no key, and a window to set; the other servers have no
        // such window. Refused here, so that nothing is sent anywhere.
        let runs = !parsed.showHelp && !parsed.showVersion && parsed.replayFiguresPath == nil
            && !parsed.checkExposure
        if runs, parsed.serverType == .ollama {
            if parsed.apiKeyFile != nil {
                throw ResearchArgumentError(
                    "--api-key-file cannot be used with --server-type ollama: Ollama on this Mac "
                        + "has no key, and SandSeek sends none to it")
            }
            if let problem = ResearchOllama.nameProblem(parsed.model) {
                throw ResearchArgumentError(problem)
            }
        }
        if runs, parsed.contextTokens != nil,
           parsed.serverType == .tuff || parsed.serverType == .llamacpp {
            throw ResearchArgumentError(
                "--context-tokens is only for Ollama (--server-type ollama or auto)")
        }
        if !parsed.showHelp && !parsed.showVersion && parsed.replayFiguresPath == nil && !parsed.checkExposure
            && parsed.question.isEmpty {
            throw ResearchArgumentError("a question is required")
        }
        return parsed
    }
}

public struct ResearchArgumentError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
