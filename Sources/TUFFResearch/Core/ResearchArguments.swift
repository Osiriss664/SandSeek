import Foundation
import TUFFModelCatalog

public struct ResearchArguments: Equatable, Sendable {
    public var question: String = ""
    public var model: String = "default"
    public var serverURL: URL = URL(
        string: "http://127.0.0.1:\(TUFFBackgroundServerSettings.defaultPort)")!
    public var sandboxURL: URL = URL(string: "http://127.0.0.1:9000")!
    public var outputPath: String?
    public var maxTokens: Int = 1_024
    public var enableThinking: Bool?
    public var quiet = false
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
      --max-tokens <n>         Completion tokens per model turn (default 1024).
      --page-chars <n>         Page text per read, 500...20000 (default 3000).
      --context-chars <n>      Prompt budget before old results are shortened
                               (default 16000).
      --thinking on|off        Gemma and Qwen reasoning (default: model's own).
      --output <file.md>       Also write the report to a new file.
      --quiet                  Do not print progress to standard error.
    """

    public init() {}

    public static func parse(_ arguments: [String]) throws -> ResearchArguments {
        var parsed = ResearchArguments()
        var words: [String] = []
        var index = 0
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
                parsed.options.maxSteps = try integer(argument, 1...32)
            case "--max-tokens":
                parsed.maxTokens = try integer(argument, 64...32_768)
            case "--page-chars":
                parsed.options.pageSliceCharacters = try integer(argument, 500...20_000)
            case "--context-chars":
                parsed.options.contextBudgetCharacters = try integer(argument, 2_000...1_000_000)
            case "--thinking":
                switch try value(argument) {
                case "on": parsed.enableThinking = true
                case "off": parsed.enableThinking = false
                default: throw ResearchArgumentError("--thinking must be on or off")
                }
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
