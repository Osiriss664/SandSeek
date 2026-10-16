import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// What SandSeek runs to start a model server, as plain data.
//
// SandSeek starts only three programs: TUFF's `TUFFServer`, llama.cpp's
// `llama-server` and Ollama's `ollama` (as `ollama serve`). It runs the program itself with a fixed list of arguments
// (no shell, so nothing in a path or a model name can become a command), on
// 127.0.0.1 only, and with an environment built from scratch. This file is
// pure, so the argument lists and the rules around them are tested on any
// platform. The files and processes are handled elsewhere.

/// Why a program, a path or a start was refused. The text is shown on the
/// model server card.
public struct ResearchLaunchProblem: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

public struct ResearchServerLaunchPlan: Equatable, Sendable {
    /// The absolute path of the program. It runs without a shell.
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// The host a started server listens on. TUFFServer has no host option
    /// and always binds 127.0.0.1; llama-server is told this one.
    public static let host = "127.0.0.1"
    public static let tuffProgramName = "TUFFServer"
    public static let llamaProgramName = "llama-server"
    public static let ollamaProgramName = "ollama"
    /// The folder name of the Ollama desktop app.
    public static let ollamaAppName = "Ollama.app"
    /// Shown on the card when the chosen Ollama is the one inside Ollama.app.
    public static let ollamaAppNote =
        "This copy of Ollama updates itself. The Homebrew version (brew install ollama) does not."
    /// Start ports below this are refused: a server SandSeek starts is never
    /// a system service.
    public static let lowestPort = 1_024

    /// TUFFServer's option names. They are the ones `TUFFServer --help` prints
    /// on TUFF 8.3.11 (`--models-root` and `--port`; there is no host option,
    /// and `--background` is never passed). If a later TUFF renames one, this
    /// is the one place to change.
    enum TUFFOption {
        static let port = "--port"
        static let modelsRoot = "--models-root"
    }

    // MARK: - Plans

    /// TUFFServer on `port`, with `modelsRoot` as its models folder when one
    /// was chosen (without it TUFFServer uses the installed TUFF's folder).
    public static func tuff(server: String, modelsRoot: String?, port: Int) throws
        -> ResearchServerLaunchPlan {
        try checkedPath(server, "The TUFFServer program")
        try checkedPort(port)
        var arguments = [TUFFOption.port, String(port)]
        if let modelsRoot {
            try checkedPath(modelsRoot, "The models folder")
            arguments += [TUFFOption.modelsRoot, modelsRoot]
        }
        return ResearchServerLaunchPlan(
            executable: server, arguments: arguments, environment: environment())
    }

    /// llama-server for one model, asking for the key in `keyFile`.
    public static func llamacpp(server: String, model: String, port: Int, keyFile: String) throws
        -> ResearchServerLaunchPlan {
        try checkedPath(server, "The llama-server program")
        try checkedPath(model, "The model file")
        try checkedPath(keyFile, "The key file")
        try checkedPort(port)
        guard model.lowercased().hasSuffix(".gguf") else {
            throw ResearchLaunchProblem("The model must be a .gguf file.")
        }
        return ResearchServerLaunchPlan(
            executable: server,
            arguments: llamaArguments(
                model: model, alias: alias(fromModelFile: model), host: host, port: port,
                keyFile: keyFile),
            environment: environment())
    }

    /// `ollama serve`, listening on 127.0.0.1 at `port` only. Besides the three
    /// variables of `environment()` it gets `OLLAMA_HOST` (the address to
    /// listen on) and `OLLAMA_NO_CLOUD` (no cloud models). Nothing else of the
    /// app's own environment is passed on, so `OLLAMA_ORIGINS`, `OLLAMA_MODELS`
    /// and the like from a session cannot reach it.
    public static func ollama(server: String, port: Int) throws -> ResearchServerLaunchPlan {
        try checkedPath(server, "The Ollama program")
        try checkedPort(port)
        var variables = environment()
        variables["OLLAMA_HOST"] = "\(host):\(port)"
        variables["OLLAMA_NO_CLOUD"] = "1"
        return ResearchServerLaunchPlan(
            executable: server, arguments: ["serve"], environment: variables)
    }

    /// The one list of llama-server arguments. The launch runs it as it is,
    /// and the start command the card offers to copy is this same list, so
    /// the two cannot differ. `--alias` is always given: without it the
    /// server lists the model by its full file path, which would then show up
    /// in the model picker and in reports. No `-v`: verbose logging prints
    /// prompts.
    public static func llamaArguments(model: String, alias: String, host: String, port: Int,
                                      keyFile: String) -> [String] {
        ["-m", model, "--alias", alias, "--host", host, "--port", String(port),
         "-c", "16384", "-np", "1", "--jinja", "--api-key-file", keyFile]
    }

    /// The name the model is listed under: the file name without `.gguf`,
    /// cut to letters, digits and `. _ -`, at most 64 characters, and never
    /// beginning with `-` (so it cannot be read as an option).
    public static func alias(fromModelFile path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".gguf") { name.removeLast(5) }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var alias = String(name.filter { allowed.contains($0) }.prefix(64))
        while alias.hasPrefix("-") { alias.removeFirst() }
        return alias.isEmpty ? "model" : alias
    }

    /// Only these three variables, and not copied from the app's own
    /// environment. That keeps `LLAMA_ARG_*` (for example a second accepted
    /// key), `DYLD_*` (injected libraries) and `TUFF_*` (kernel switches) out
    /// of a server SandSeek starts. The values come from the system, not from
    /// `$HOME` or `$TMPDIR`, which a session can set: the home folder from the
    /// account database, the temporary folder from `confstr`.
    public static func environment(
        home: String = userHome(), tmp: String = userTemporaryFolder()
    ) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": tmp]
    }

    /// The home folder from the account database (`getpwuid`).
    public static func userHome() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let home = String(cString: directory)
            if home.hasPrefix("/") { return home }
        }
        return NSHomeDirectory()
    }

    /// The user's temporary folder (`confstr`, `/var/folders/...` on macOS).
    public static func userTemporaryFolder() -> String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        #endif
        return "/tmp/"
    }

    // MARK: - Checks

    /// A path must be absolute (so it can never read as an option) and hold
    /// no control or invisible characters, newlines included.
    @discardableResult
    public static func checkedPath(_ path: String, _ what: String) throws -> String {
        guard path.hasPrefix("/"), ResearchText.terminalSafe(path) == path,
              !path.contains("\n"), !path.contains("\t") else {
            throw ResearchLaunchProblem(
                "\(what) needs a full path (beginning with /) without control characters.")
        }
        return path
    }

    static func checkedPort(_ port: Int) throws {
        guard (lowestPort...65_535).contains(port) else {
            throw ResearchLaunchProblem(
                "Start needs a port from \(lowestPort) to 65535 in the server address.")
        }
    }

    /// The `TUFFServer` to start for what the person picked. `tuff serve`
    /// runs TUFFServer as a child and does not pass signals on, so stopping
    /// `tuff` would leave TUFFServer running with the model loaded. A pick of
    /// `tuff`, or of TUFF.app, therefore becomes the `TUFFServer` beside it
    /// (in the app: `Contents/Resources/bin`). Any other file name is refused.
    public static func tuffServerPath(
        forPick pick: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> String {
        try checkedPath(pick, "The program")
        var path = pick
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
        let server: String
        if name.lowercased().hasSuffix(".app") {
            server = path + "/Contents/Resources/bin/" + tuffProgramName
        } else if name == "tuff" {
            server = (path as NSString).deletingLastPathComponent + "/" + tuffProgramName
        } else if name == tuffProgramName {
            server = path
        } else {
            throw ResearchLaunchProblem(
                "Choose TUFFServer, tuff or TUFF.app. SandSeek starts TUFFServer itself, "
                    + "because stopping `tuff` would leave TUFFServer running.")
        }
        guard fileExists(server) else {
            throw ResearchLaunchProblem("\(server) does not exist.")
        }
        return server
    }

    /// A TUFF built from a clone keeps its models in `<clone>/scratch`, not in
    /// Application Support. For a program at `<clone>/.build/release/TUFFServer`
    /// this is that folder. It is only where the folder chooser opens: the
    /// folder is never passed to TUFFServer unless the person chooses it.
    public static func cloneModelsHint(forProgram path: String) -> String? {
        guard let range = path.range(of: "/.build/") else { return nil }
        let clone = String(path[..<range.lowerBound])
        return clone.isEmpty ? nil : clone + "/scratch"
    }

    /// llama.cpp's server must be a program called `llama-server`.
    public static func llamaServerPath(forPick pick: String) throws -> String {
        try checkedPath(pick, "The program")
        guard (pick as NSString).lastPathComponent == llamaProgramName else {
            throw ResearchLaunchProblem("Choose the program called \(llamaProgramName).")
        }
        return pick
    }

    /// The `ollama` program to start for what the person picked: a file called
    /// `ollama`, or Ollama.app, which maps to the program inside it
    /// (`Contents/Resources/ollama`). Any other name is refused.
    public static func ollamaPath(
        forPick pick: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> String {
        try checkedPath(pick, "The program")
        var path = pick
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
        if name == ollamaAppName {
            let program = path + "/Contents/Resources/" + ollamaProgramName
            guard fileExists(program) else {
                throw ResearchLaunchProblem("\(program) does not exist.")
            }
            return program
        }
        guard name == ollamaProgramName else {
            throw ResearchLaunchProblem(
                "Choose the program called \(ollamaProgramName), or \(ollamaAppName).")
        }
        return path
    }

    /// True when the program is inside an app, such as Ollama.app, which
    /// updates itself.
    public static func isInsideApp(_ path: String) -> Bool {
        path.contains(".app/")
    }

    /// Where the folder chooser for Ollama opens: the Homebrew program if it
    /// exists (Apple silicon, then Intel). Nothing is chosen for the person.
    public static func ollamaSuggestion(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first(where: fileExists)
    }
}
