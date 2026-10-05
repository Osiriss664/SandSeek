import Foundation
import TUFFModelCatalog

public struct ResearchArguments: Equatable, Sendable {
    public var question: String = ""
    public var model: String = "default"
    public var serverURL: URL = URL(
        string: "http://127.0.0.1:\(TUFFBackgroundServerSettings.defaultPort)")!
    public var sandboxURL: URL = URL(string: "http://127.0.0.1:9000")!
    public var outputPath: String?
    public var maxTokens: Int = 2_048
    public var enableThinking: Bool?
    public var showThinking = false
    public var quiet = false
    /// Minutes one model step may take before it is retried without reasoning.
    public var stepTimeoutMinutes = ResearchOptions.defaultStepTimeoutMinutes
    public var showHelp = false
    public var options = ResearchOptions()

    public static let usage = """
    usage: tuff research <question> [options]

    Researches a question on the web with a local TUFF model. Web pages are
    fetched by the sandbox, a small server in an Apple container Linux VM
    (Scripts/research_sandbox.sh start). The model can only search and read
    pages; it cannot run commands or touch files.

    options:
      --model <name>           Model the server should use (default: default,
                               the model selected in TUFF).
      --server <url>           TUFF server (default: http://127.0.0.1:8080).
      --sandbox <url>          Web sandbox (default: http://127.0.0.1:9000).
      --max-steps <1...32>     Model turns that may use tools (default 8).
      --max-tokens <n>         Completion tokens per model turn, 64...32768
                               (default 2048, or 8192 with reasoning on).
      --page-chars <n>         Page text per read, 500...20000 (default 3000).
      --context-chars <n>      Prompt budget before old results are shortened,
                               2000...1000000 (default: from the model's
                               context window, or 16000 when not listed).
      --search-results <1...10>
                               Results per search (default 5).
      --tool-calls <1...8>     Tool calls the model may make per turn
                               (default 4).
      --min-pages <1...6>      Pages the research should read; the prompt asks
                               for this many and the loop opens top results
                               to reach it (default 3).
      --auto-open on|off       Let the loop open top results itself when the
                               model reads too few pages (default on).
      --nudges on|off          Ask the model once to search, to open pages, or
                               to look wider when it answers too early
                               (default on).
      --rewrite on|off         Ask once for a rewrite when the answer cites
                               pages that were never read (default on).
      --step-timeout <1...60>  Minutes one model step may take before it is
                               retried without reasoning (default 30).
      --thinking on|off        Gemma and Qwen reasoning (default: model's own).
      --show-thinking          Turn reasoning on and print it with the
                               progress. It is not added to the report.
      --output <file.md>       Also write the report to a new file.
      --quiet                  Do not print progress to standard error.
    """

    public init() {}

    public static func parse(_ arguments: [String]) throws -> ResearchArguments {
        var parsed = ResearchArguments()
        var words: [String] = []
        var index = 0
        var maxTokensGiven = false
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
            switch argument {
            case "--help", "-h":
                parsed.showHelp = true
            case "--model":
                parsed.model = try value(argument)
            case "--server":
                parsed.serverURL = try ResearchEndpoint.loopbackURL(try value(argument), flag: argument)
            case "--sandbox":
                parsed.sandboxURL = try ResearchEndpoint.loopbackURL(try value(argument), flag: argument)
            case "--max-steps":
                parsed.options.maxSteps = try integer(argument, ResearchOptions.maxStepsRange)
            case "--max-tokens":
                parsed.maxTokens = try integer(argument, ResearchOptions.maxTokensRange)
                maxTokensGiven = true
            case "--page-chars":
                parsed.options.pageSliceCharacters = try integer(
                    argument, ResearchOptions.pageCharactersRange)
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
            case "--rewrite":
                parsed.options.reviseUnreadCitations = try onOff(argument)
            case "--step-timeout":
                parsed.stepTimeoutMinutes = try integer(
                    argument, ResearchOptions.stepTimeoutMinutesRange)
            case "--thinking":
                parsed.enableThinking = try onOff(argument)
            case "--show-thinking":
                parsed.showThinking = true
            case "--output":
                parsed.outputPath = try value(argument)
            case "--quiet":
                parsed.quiet = true
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
        if !parsed.showHelp && parsed.question.isEmpty {
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
