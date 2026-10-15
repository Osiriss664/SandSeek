import Foundation
import Observation
import SandSeekCore

public struct ResearchServedModel: Equatable, Identifiable, Hashable, Sendable {
    /// The id the server routes by, such as `qwen3.6-35b-a3b`, or the
    /// `--alias` a llama.cpp server was started with.
    public let id: String
    public var displayName: String { id }

    public init(id: String) {
        self.id = id
    }
}

/// The kinds of model server the picker shows. TUFF, llama.cpp and Ollama
/// have a connector (Ollama's is experimental); LM Studio is listed so that
/// people see it is planned, but it cannot be chosen yet.
public enum ResearchServerType: String, CaseIterable, Identifiable, Sendable {
    case tuff
    case llamacpp
    case ollama
    case lmstudio

    public var id: String { rawValue }

    /// The connector this type uses, or nil for a type that comes later.
    public var kind: ResearchServerKind? {
        switch self {
        case .tuff: .tuff
        case .llamacpp: .llamacpp
        case .ollama: .ollama
        case .lmstudio: nil
        }
    }

    public var isAvailable: Bool { kind != nil }

    /// Whether "Start server" can start a server of this type. Ollama is
    /// started by the person (`ollama serve`); SandSeek never starts or
    /// stops it.
    public var canStart: Bool { self == .tuff || self == .llamacpp }

    public var displayName: String {
        switch self {
        case .tuff: "TUFF"
        case .llamacpp: "llama.cpp"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        }
    }

    /// The name in the picker: a type that comes later says so.
    public var pickerLabel: String {
        isAvailable ? displayName : displayName + " (later)"
    }

    /// Where a server of this type listens unless it was started otherwise.
    public var defaultAddress: String? {
        switch self {
        case .tuff: "http://127.0.0.1:8080"
        case .llamacpp: "http://127.0.0.1:8081"
        case .ollama: "http://127.0.0.1:11434"
        case .lmstudio: nil
        }
    }
}

/// Keeps the key SandSeek sends to llama.cpp. The key is made once by the app
/// and shown only in the start command it offers to copy.
public protocol ResearchKeyStoring {
    func loadKey() -> String?
    func saveKey(_ key: String) throws
    /// The file that holds the key, when it is kept in one. llama-server is
    /// started with `--api-key-file` and this path, so the key itself is on no
    /// command line.
    var keyFilePath: String? { get }
}

public extension ResearchKeyStoring {
    var keyFilePath: String? { nil }
}

/// The key in a file only the person can read (mode 0600, in a folder with
/// mode 0700).
public struct FileKeyStore: ResearchKeyStoring {
    public let url: URL

    public init(url: URL = FileKeyStore.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("SandSeek/State/llamacpp-api-key")
    }

    public var keyFilePath: String? { url.path }

    public func loadKey() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public func saveKey(_ key: String) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // A folder that existed before keeps its mode, so set it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(key.utf8),
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The model server a question is sent to. This controller connects to a
/// server on this Mac's loopback address only: it holds the chosen type and
/// address, looks at the server now and then, and lists its models. It never
/// starts or stops a server itself; "Start server" and "Stop server" belong to
/// `ResearchServerLaunchController`, which stops only a server SandSeek started.
@MainActor @Observable
public final class ResearchServerController {
    public enum State: Equatable, Sendable {
        /// Not looked at yet (or the type or address just changed).
        case notChecked
        case checking
        /// Answers as the chosen type and lists models.
        case ready
        /// Nothing answers at the address.
        case off
        /// Something answers, but a question cannot be sent: not the chosen
        /// type, the key was refused, or no model is listed.
        case problem(String)

        public var isBusy: Bool { self == .checking }
    }

    /// What one full look at the server found.
    enum Outcome: Equatable, Sendable {
        case ready(models: [ResearchServedModel], version: String?, contextTokens: Int?)
        case off(String)
        case problem(String)
    }

    /// What the cheap look found: the server's status route only.
    enum QuickLook: Equatable, Sendable {
        /// It answers as before.
        case alive
        /// It does not answer.
        case gone(String)
        /// It answers differently than a ready server does (not TUFF any
        /// more, llama.cpp still loading its model): look at it in full.
        case changed
    }

    /// What the last Check found out about the server being reachable from
    /// the network (see `ResearchExposureCheck`).
    public enum Exposure: Equatable, Sendable {
        /// Not looked at: no Check since the type or address changed, or the
        /// server did not answer.
        case notChecked
        case checking
        /// Every connection to this Mac's own network addresses was refused.
        /// `addresses` is how many were tried (0: the Mac has none).
        case notReachable(addresses: Int)
        /// No connection was accepted, but some address neither accepted nor
        /// refused (a timeout, a block, a missing permission), so nothing can
        /// be said. The text is the note to show.
        case unclear(String)
        /// A connection to a network address was accepted. The text is the
        /// warning to show.
        case reachable(String)
    }

    public static let memoryNote =
        "On a Mac with 16 GB, run only one model server with a loaded model at a time."
    public static let keyNote =
        "SandSeek made a key for llama.cpp and keeps it in a file only you can read. "
        + "Start llama-server with that file (--api-key-file) so that it asks for the key; "
        + "SandSeek sends it with every request."

    /// Seconds a request to the server may take before it is reported as not
    /// answering. The transport's own limit is longer, so this one is the one
    /// the message names: a busy server is not reported as gone after 3 s.
    nonisolated static let requestTimeout: TimeInterval = 8
    /// The sandbox's port inside its VM, and the port assumed for it when none
    /// is recorded. A model server at this port is refused, and so is one at
    /// the port the last sandbox start recorded, so the llama.cpp key can never
    /// be sent to the sandbox. Kept equal to `ResearchSandboxController.port`
    /// (a test checks it).
    nonisolated static let sandboxPort = ResearchSandboxFiles.fallbackPort

    static let typeKey = "ResearchServerType"
    static func addressKey(_ type: ResearchServerType) -> String {
        "ResearchServerAddress-" + type.rawValue
    }

    public private(set) var serverType: ResearchServerType
    public private(set) var addressText: String
    public private(set) var state: State = .notChecked
    public private(set) var models: [ResearchServedModel] = []
    /// What the last successful look found out about the server.
    public private(set) var connection: ResearchServerConnection?
    /// Why nothing answered, when `state` is `.off`.
    public private(set) var offReason: String?
    public private(set) var lastChecked: Date?
    /// Set when the llama.cpp key could not be written to disk.
    public private(set) var keyProblem: String?
    /// Whether the server could be reached from the network, found by the
    /// last Check (not by the periodic look).
    public private(set) var exposure: Exposure = .notChecked
    /// The key SandSeek sends to llama.cpp. It is used in one request header
    /// and is never shown, copied, logged or put into a command.
    public let apiKey: String
    /// The file that holds `apiKey`, for the start command.
    public let keyFilePath: String?

    private let defaults: any ResearchSettingsStore
    private let transport: any ResearchHTTPTransport
    /// Whether TUFF's replies are read as a stream. On, as the plan says: that
    /// is what makes Stop reach a TUFF that has not been changed. The switch
    /// is the plan's way back to plain requests for a server that streams
    /// wrongly; llama.cpp is always plain for now (its connector is 2b).
    private let tuffStreaming: Bool
    /// Tries this Mac's network addresses on a port. Nil: the exposure check
    /// is off, as in most tests; the app passes `networkExposureCheck`.
    private let exposureProbe: (@Sendable (Int) async -> ResearchExposureReport)?
    @ObservationIgnored private var generation = 0
    /// Counts the exposure checks and the changes of type or address, so that
    /// an answer that is no longer wanted is dropped.
    @ObservationIgnored private var exposureGeneration = 0

    /// The real check: a TCP connect to each of this Mac's network addresses.
    public nonisolated static let networkExposureCheck:
        @Sendable (Int) async -> ResearchExposureReport = { port in
        await ResearchExposureCheck.run(port: port)
    }

    public init(defaults: any ResearchSettingsStore = UserDefaults.standard,
                keyStore: any ResearchKeyStoring = FileKeyStore(),
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 10),
                tuffStreaming: Bool = true,
                exposureCheck: (@Sendable (Int) async -> ResearchExposureReport)? = nil) {
        self.defaults = defaults
        self.transport = transport
        self.tuffStreaming = tuffStreaming
        exposureProbe = exposureCheck
        keyFilePath = keyStore.keyFilePath
        let saved = defaults.savedString(forKey: Self.typeKey)
            .flatMap(ResearchServerType.init(rawValue:))
        let type = saved.flatMap { $0.isAvailable ? $0 : nil } ?? .tuff
        serverType = type
        addressText = defaults.savedString(forKey: Self.addressKey(type))
            ?? type.defaultAddress ?? ""
        if let stored = keyStore.loadKey() {
            apiKey = stored
        } else {
            let made = Self.makeKey()
            apiKey = made
            do {
                try keyStore.saveKey(made)
            } catch {
                keyProblem = "The key for llama.cpp could not be saved: "
                    + error.localizedDescription + ". It is only valid until SandSeek quits."
            }
        }
    }

    /// 32 random bytes from the system's secure generator, as hex (so it is
    /// safe in a shell command).
    static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    // MARK: - Choosing the server

    /// Chooses a type. A type that comes later is ignored. The address
    /// changes to the one last used for this type, or its default.
    public func select(_ type: ResearchServerType) {
        guard type.isAvailable, type != serverType else { return }
        serverType = type
        addressText = defaults.savedString(forKey: Self.addressKey(type))
            ?? type.defaultAddress ?? ""
        defaults.save(type.rawValue, forKey: Self.typeKey)
        resetStatus()
    }

    /// Takes what the person typed. It is checked when the server is looked at.
    public func setAddress(_ text: String) {
        guard text != addressText else { return }
        addressText = text
        defaults.save(text, forKey: Self.addressKey(serverType))
        resetStatus()
    }

    /// Puts the default address of the chosen type back.
    public func restoreDefaultAddress() {
        setAddress(serverType.defaultAddress ?? "")
    }

    /// Forgets what the last exposure check found, and any check still under
    /// way: the server it was about is gone or was changed.
    private func dropExposure() {
        exposureGeneration += 1
        exposure = .notChecked
    }

    private func resetStatus() {
        generation += 1
        dropExposure()
        state = .notChecked
        models = []
        connection = nil
        offReason = nil
    }

    /// The server address as an URL, only if it is an http address with a
    /// port on this Mac's loopback interface, and not the sandbox's port.
    /// `127.0.0.1:8080` without a scheme is read as `http://127.0.0.1:8080`. A
    /// path other than `/v1` is refused.
    public nonisolated static func parseAddress(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        let url = try ResearchEndpoint.loopbackURL(text, flag: "The server address")
        guard url.path.isEmpty || url.path == "/v1" else {
            throw ResearchError.invalidEndpoint(
                "The server address must not have a path; use the address alone, such as "
                    + "http://127.0.0.1:8080")
        }
        guard let port = url.port else {
            throw ResearchError.invalidEndpoint(
                "The server address needs a port, such as http://127.0.0.1:8080")
        }
        let recorded = try? ResearchSandboxFiles.readPort(in: ResearchSandboxFiles.defaultFolder)
        guard port != sandboxPort, port != recorded else {
            throw ResearchError.invalidEndpoint(
                "Port \(port) is the web sandbox's. Give the model server another port.")
        }
        return url
    }

    /// The address as an URL, or nil when it is not a loopback address.
    public var serverURL: URL? { try? Self.parseAddress(addressText) }

    /// Why the address is refused, or nil when it is fine.
    public var addressProblem: String? {
        do {
            _ = try Self.parseAddress(addressText)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// The `Authorization` value for requests to the chosen server: a Bearer
    /// token for llama.cpp, nothing for TUFF.
    public var authorization: String? {
        Self.authorization(for: serverType.kind, key: apiKey)
    }

    nonisolated static func authorization(for kind: ResearchServerKind?, key: String) -> String? {
        kind == .llamacpp ? "Bearer " + key : nil
    }

    // MARK: - How to start a server

    /// The command that starts a llama.cpp server SandSeek can use. It names
    /// the key file and holds no key, so it can be shown and copied: the key
    /// itself would show in `ps` for every user of this Mac and stay in the
    /// shell history. The port follows the address. The arguments are the list
    /// "Start server" runs (`ResearchServerLaunchPlan.llamaArguments`), with
    /// placeholders for the model and its name.
    ///
    /// `--api-key-file` is the flag the plan assumes; the llama.cpp probe on
    /// the Mac confirms that llama-server has it and enforces it.
    public var startCommand: String? {
        guard serverType == .llamacpp else { return nil }
        let url = serverURL
        let arguments = ResearchServerLaunchPlan.llamaArguments(
            model: "<model.gguf>", alias: "<name>",
            host: url?.host == "::1" ? "::1" : ResearchServerLaunchPlan.host,
            port: url?.port ?? 8081, keyFile: keyFilePath ?? "<key file>")
        return (["llama-server"] + arguments).map(Self.shellWord).joined(separator: " ")
    }

    /// One word of a command: left as it is when it is plain, otherwise
    /// quoted (a path always is).
    nonisolated static func shellWord(_ text: String) -> String {
        text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_:".contains($0)) }
            ? text : shellQuoted(text)
    }

    /// `text` in single quotes for a shell; a path with a space stays one word.
    nonisolated static func shellQuoted(_ text: String) -> String {
        guard text.hasPrefix("<") == false else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The hint for the chosen type, for when the server is off.
    public var startHint: String {
        switch serverType {
        case .tuff:
            "Choose TUFFServer below and click Start server, or start TUFF's Background API "
                + "in its Server screen, or (with the `tuff` command installed) run `tuff serve`. "
                + "TUFF listens on 127.0.0.1:8080 unless you changed it."
        case .llamacpp:
            "Choose llama-server and a model below and click Start server, or start llama.cpp "
                + "with the command below. Replace <model.gguf> with your model "
                + "file and <name> with the name you want in the model list."
        case .ollama:
            "Start Ollama yourself: run `ollama serve` (it listens on 127.0.0.1:11434) and "
                + "install a model that can call tools with `ollama pull <name>`. "
                + "SandSeek does not start or stop Ollama. Ollama support is experimental."
        case .lmstudio:
            "\(serverType.displayName) support comes later."
        }
    }

    /// True for llama.cpp when the server did not say how large its context
    /// window is (or is not looked at yet): the run then uses a small prompt
    /// budget, which Settings can replace.
    public var needsPromptBudget: Bool {
        serverType == .llamacpp && connection?.contextTokens == nil
    }

    // MARK: - Looking at the server

    /// Looks at the server now and shows that it is looking. For the Check
    /// button. Then, if a server answers, tries the Mac's network addresses on
    /// its port to see whether it is reachable from the network. That is done
    /// here only, not on the periodic look: it makes a connection attempt per
    /// address.
    public func check() async {
        await look(showProgress: true)
        await checkExposure()
    }

    /// Whether something that answers on the chosen port can also be reached
    /// at the Mac's network addresses. Nothing is sent to it; see
    /// `ResearchExposureCheck`.
    private func checkExposure() async {
        guard let probe = exposureProbe else { return }
        guard let port = serverURL?.port else {
            dropExposure()
            return
        }
        // A server that answers can be reachable. One that does not, or an
        // address that was changed meanwhile, has nothing to check.
        switch state {
        case .ready, .problem:
            break
        case .notChecked, .checking, .off:
            dropExposure()
            return
        }
        exposureGeneration += 1
        let mine = exposureGeneration
        exposure = .checking
        let report = await probe(port)
        guard mine == exposureGeneration else { return }
        if let warning = report.warning(for: serverType.kind) {
            exposure = .reachable(warning)
        } else if let note = report.unknownNote {
            exposure = .unclear(note)
        } else {
            exposure = .notReachable(addresses: report.checked.count)
        }
    }

    /// Asks the server for its model list again, without changing what the
    /// card shows until the answer is in. For the button beside the model
    /// picker.
    public func refreshModels() async {
        guard state != .checking else { return }
        await look(showProgress: false)
    }

    /// The periodic look. A server that is ready is asked only its status
    /// route (TUFF `/tuff/v1/status`, llama.cpp `/health`), which costs
    /// nothing; the model list is fetched again only when that route says
    /// something changed, on Check, or from the model picker's button. Any
    /// other state is looked at in full, since the server may have come up.
    ///
    /// TUFF unloads its model after a time without requests. Whether this
    /// route counts as a request, so that an open window would keep the model
    /// in memory, is checked on the Mac (the idle-unload check of step 3).
    public func refresh() async {
        guard let kind = serverType.kind, let url = serverURL else {
            await look(showProgress: false)
            return
        }
        switch state {
        case .checking:
            return
        case .notChecked, .problem:
            await look(showProgress: false)
        case .ready, .off:
            let mine = generation
            let quick = await Self.quickLook(kind: kind, url: url, transport: transport)
            // The person changed the type or address meanwhile: this answer is old.
            guard mine == generation else { return }
            lastChecked = Date()
            switch (quick, state) {
            case (.alive, .ready):
                return
            case (.gone(let reason), _):
                if state != .off || offReason != reason {
                    models = []
                    connection = nil
                    offReason = reason
                    state = .off
                    dropExposure()
                }
            default:
                // A server that changed (restarted, another one on the port) is
                // not the one an earlier Check looked at.
                dropExposure()
                await look(showProgress: false)
            }
        }
    }

    private func look(showProgress: Bool) async {
        let type = serverType
        let text = addressText
        guard let kind = type.kind else {
            state = .problem("\(type.displayName) support comes later.")
            return
        }
        // Whatever was still on its way is old from here on.
        generation += 1
        let url: URL
        do {
            url = try Self.parseAddress(text)
        } catch {
            models = []
            connection = nil
            state = .problem(String(describing: error))
            return
        }
        if showProgress { state = .checking }
        let mine = generation
        let outcome = await Self.inspect(
            kind: kind, url: url, authorization: Self.authorization(for: kind, key: apiKey),
            transport: transport)
        // The person changed the type or address meanwhile: this answer is old.
        guard mine == generation else { return }
        lastChecked = Date()
        switch outcome {
        case .ready(let listed, let version, let contextTokens):
            models = listed
            // Ollama is always streamed: it stops generating when the client
            // hangs up, which is what makes Stop work.
            connection = ResearchServerConnection(
                kind: kind, version: version,
                streaming: (kind == .tuff && tuffStreaming) || kind == .ollama,
                contextTokens: contextTokens)
            offReason = nil
            state = .ready
        case .off(let reason):
            models = []
            connection = nil
            offReason = reason
            state = .off
            dropExposure()
        case .problem(let message):
            models = []
            connection = nil
            offReason = nil
            state = .problem(message)
        }
    }

    /// `/v1/models` and `/props` live at the server's root, whether the
    /// address ends in `/v1` or not.
    nonisolated static func endpoint(_ url: URL, _ path: String) -> URL? {
        var base = url.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + path)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? URLError, error.code == .timedOut {
            return "no answer within \(Int(requestTimeout)) seconds"
        }
        return error.localizedDescription
    }

    /// The cheap look: TUFF's status route, llama.cpp's `/health` (which
    /// llama-server answers without a key, 503 while it loads its model),
    /// Ollama's `/api/version`.
    nonisolated static func quickLook(kind: ResearchServerKind,
                                      url: URL,
                                      transport: any ResearchHTTPTransport) async -> QuickLook {
        switch kind {
        case .tuff:
            switch await ResearchServerConnection.probe(
                serverURL: url, transport: transport, timeout: requestTimeout) {
            case .tuff: return .alive
            case .unreachable(let reason): return .gone(reason)
            case .other: return .changed
            }
        case .ollama:
            switch await ResearchServerConnection.probeOllama(
                serverURL: url, transport: transport, timeout: requestTimeout) {
            case .ollama: return .alive
            case .unreachable(let reason): return .gone(reason)
            case .other: return .changed
            }
        case .llamacpp:
            guard let health = endpoint(url, "/health") else { return .changed }
            do {
                let response = try await transport.send(
                    method: "GET", url: health, body: nil, timeout: requestTimeout)
                // A key refusal is found by the full look, not here; so is a
                // redirect, which is never followed.
                return [200, 401, 403].contains(response.status) ? .alive : .changed
            } catch {
                return .gone(describe(error))
            }
        }
    }

    /// What llama.cpp's `/props` said.
    enum Props: Equatable, Sendable {
        /// Looks like llama.cpp; `n_ctx` when it is there.
        case llamacpp(contextTokens: Int?)
        case keyRefused(Int)
        /// A 3xx answer, which is never followed.
        case redirected(Int)
        case notLlamaCpp(String)
        case off(String)
    }

    /// Asks `/props` with the key. The shapes below are what recent
    /// llama-server builds answer; the check is tolerant (any JSON object
    /// with `default_generation_settings` is llama.cpp, `n_ctx` is optional)
    /// because the llama.cpp probe on the Mac confirms them.
    nonisolated static func props(url: URL,
                                  authorization: String?,
                                  transport: any ResearchHTTPTransport) async -> Props {
        guard let propsURL = endpoint(url, "/props") else {
            return .notLlamaCpp("the server address cannot be extended to /props")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: propsURL, body: nil, timeout: requestTimeout,
                authorization: authorization)
        } catch {
            return .off(describe(error))
        }
        switch response.status {
        case 200:
            break
        case 401, 403:
            return .keyRefused(response.status)
        case 300..<400:
            return .redirected(response.status)
        default:
            return .notLlamaCpp("HTTP \(response.status) from /props")
        }
        guard let json = try? ResearchJSON.decode(response.body), json.objectValue != nil,
              let settings = json["default_generation_settings"], settings.objectValue != nil
        else {
            return .notLlamaCpp("no default_generation_settings in /props")
        }
        let window = settings["n_ctx"]?.intValue
        return .llamacpp(contextTokens: window.flatMap { $0 > 0 ? $0 : nil })
    }

    /// The rest of a sentence that begins "A server answers at <address>, but".
    nonisolated static func redirectNote(_ status: Int) -> String {
        "it answered with a redirect (HTTP \(status)), which SandSeek refuses. It never follows "
            + "redirects from the model server, and none of TUFF, llama.cpp and Ollama redirects, so "
            + "another program may be using this port."
    }

    nonisolated static func keyRefusedMessage(_ status: Int) -> String {
        "The server refused the key (HTTP \(status)). Start llama-server again with the "
            + "command below, so that it uses the key file SandSeek sends."
    }

    /// Asks the server who it is and which models it lists. The chosen type
    /// must match what answers: a TUFF address that does not answer TUFF's
    /// status route, or a llama.cpp address that answers it or whose `/props`
    /// does not look like llama.cpp, is reported as it is.
    nonisolated static func inspect(kind: ResearchServerKind,
                                    url: URL,
                                    authorization: String?,
                                    transport: any ResearchHTTPTransport) async -> Outcome {
        if kind == .ollama {
            return await inspectOllama(url: url, transport: transport)
        }
        let probe = await ResearchServerConnection.probe(
            serverURL: url, transport: transport, timeout: requestTimeout)
        var version: String?
        var contextTokens: Int?
        switch (kind, probe) {
        case (_, .unreachable(let reason)):
            return .off(reason)
        case (_, .other(let status)) where (300..<400).contains(status):
            return .problem("A server answers at \(url.absoluteString), but \(redirectNote(status))")
        case (.tuff, .other(let status)):
            if case .ollama = await ResearchServerConnection.probeOllama(
                serverURL: url, transport: transport, timeout: requestTimeout) {
                return .problem("An Ollama server answers at \(url.absoluteString), not TUFF. "
                    + "Choose Ollama, or give TUFF another port.")
            }
            return .problem("A server answers at \(url.absoluteString), but not as TUFF "
                + "(HTTP \(status) from /tuff/v1/status). TUFF older than 8.3.1 has no status "
                + "route. If it is llama.cpp or Ollama, choose that.")
        case (.llamacpp, .tuff):
            return .problem("A TUFF server answers at \(url.absoluteString), not llama.cpp. "
                + "Choose TUFF, or give llama.cpp another port.")
        case (.tuff, .tuff(let found)):
            version = found
        default:
            break
        }
        if kind == .llamacpp {
            switch await props(url: url, authorization: authorization, transport: transport) {
            case .llamacpp(let window):
                contextTokens = window
            case .keyRefused(let status):
                return .problem(keyRefusedMessage(status))
            case .redirected(let status):
                return .problem("A server answers at \(url.absoluteString), but "
                    + redirectNote(status))
            case .notLlamaCpp(let detail):
                return .problem("A server answers at \(url.absoluteString), but it does not "
                    + "look like llama.cpp (\(detail)). If it is TUFF or Ollama, choose that. "
                    + "LM Studio is not supported yet.")
            case .off(let reason):
                return .off(reason)
            }
        }
        guard let modelsURL = endpoint(url, "/v1/models") else {
            return .problem("The server address cannot be extended to /v1/models.")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: modelsURL, body: nil, timeout: requestTimeout,
                authorization: authorization)
        } catch {
            return .off(describe(error))
        }
        switch response.status {
        case 200:
            break
        case 401, 403:
            return .problem(keyRefusedMessage(response.status))
        case 300..<400:
            return .problem("A server answers at \(url.absoluteString), but "
                + redirectNote(response.status))
        default:
            return .problem("The server answered /v1/models with HTTP \(response.status).")
        }
        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: response.body) else {
            return .problem("The server's /v1/models answer is not a list of models.")
        }
        guard !list.data.isEmpty else {
            return .problem("The server is running but lists no model. Load one first.")
        }
        // The same id twice would collide in the picker.
        var seen = Set<String>()
        let listed = list.data.map(\.id).filter { seen.insert($0).inserted }
            .map { ResearchServedModel(id: $0) }
        return .ready(models: listed, version: version, contextTokens: contextTokens)
    }

    /// Asks an Ollama server who it is and which models it has. `/api/version`
    /// says it is Ollama (and which version); `/api/tags` lists the models
    /// installed on this Mac. Only a model SandSeek can use is listed:
    /// - a cloud model (Ollama gives it a `remote_host`, or its name ends in
    ///   `:cloud` or `-cloud`) is left out, because its requests go to
    ///   ollama.com and the question would leave this Mac;
    /// - a model whose `capabilities` do not include `tools` is left out,
    ///   because the research needs a model that can call tools. A model with
    ///   no `capabilities` field at all (an older Ollama) is kept.
    nonisolated static func inspectOllama(url: URL,
                                          transport: any ResearchHTTPTransport) async -> Outcome {
        let version: String
        switch await ResearchServerConnection.probeOllama(
            serverURL: url, transport: transport, timeout: requestTimeout) {
        case .unreachable(let reason):
            return .off(reason)
        case .other(let status) where (300..<400).contains(status):
            return .problem("A server answers at \(url.absoluteString), but \(redirectNote(status))")
        case .other(let status):
            if case .tuff = await ResearchServerConnection.probe(
                serverURL: url, transport: transport, timeout: requestTimeout) {
                return .problem("A TUFF server answers at \(url.absoluteString), not Ollama. "
                    + "Choose TUFF, or give Ollama another port.")
            }
            return .problem("A server answers at \(url.absoluteString), but not as Ollama "
                + "(HTTP \(status) from /api/version). If it is TUFF or llama.cpp, choose that.")
        case .ollama(let found):
            version = found
        }
        guard let tagsURL = endpoint(url, "/api/tags") else {
            return .problem("The server address cannot be extended to /api/tags.")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: tagsURL, body: nil, timeout: requestTimeout)
        } catch {
            return .off(describe(error))
        }
        switch response.status {
        case 200:
            break
        case 300..<400:
            return .problem("A server answers at \(url.absoluteString), but "
                + redirectNote(response.status))
        default:
            return .problem("Ollama answered /api/tags with HTTP \(response.status).")
        }
        guard let tags = try? ResearchJSON.decode(response.body),
              let entries = tags["models"]?.arrayValue else {
            return .problem("Ollama's /api/tags answer is not a list of models.")
        }
        var seen = Set<String>()
        var usable: [ResearchServedModel] = []
        var cloudCount = 0
        var withoutToolsCount = 0
        for entry in entries {
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue,
                  !name.isEmpty else { continue }
            let host = entry["remote_host"]?.stringValue ?? ""
            if !host.isEmpty || ResearchOllama.isCloudModelName(name) {
                cloudCount += 1
                continue
            }
            if let capabilities = entry["capabilities"]?.arrayValue,
               !capabilities.contains(where: { $0.stringValue == "tools" }) {
                withoutToolsCount += 1
                continue
            }
            if seen.insert(name).inserted { usable.append(ResearchServedModel(id: name)) }
        }
        guard !usable.isEmpty else {
            return .problem(noUsableOllamaModelMessage(
                installed: entries.count, cloud: cloudCount, withoutTools: withoutToolsCount))
        }
        return .ready(models: usable, version: version, contextTokens: nil)
    }

    /// Why Ollama has no model to offer.
    nonisolated static func noUsableOllamaModelMessage(installed: Int, cloud: Int,
                                                       withoutTools: Int) -> String {
        if installed == 0 {
            return "Ollama is running but has no model installed. Install one that can call "
                + "tools with `ollama pull <name>`."
        }
        var reasons: [String] = []
        if cloud > 0 {
            reasons.append("cloud models are not used, because the question would leave this Mac")
        }
        if withoutTools > 0 {
            reasons.append("no installed model can call tools, which the research needs")
        }
        return "Ollama has no model SandSeek can use: " + reasons.joined(separator: "; ")
            + ". Install a model with tool support using `ollama pull <name>`."
    }
}
