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

/// The kinds of model server the picker shows. TUFF and llama.cpp have a
/// connector; Ollama and LM Studio are listed so that people see they are
/// planned, but they cannot be chosen yet.
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
        case .ollama, .lmstudio: nil
        }
    }

    public var isAvailable: Bool { kind != nil }

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
        case .ollama, .lmstudio: nil
        }
    }
}

/// Keeps the key SandSeek sends to llama.cpp. The key is made once by the app
/// and shown only in the start command it offers to copy.
public protocol ResearchKeyStoring {
    func loadKey() -> String?
    func saveKey(_ key: String) throws
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

    public func loadKey() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public func saveKey(_ key: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(key.utf8),
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// The model server a question is sent to. SandSeek never starts or stops a
/// server: it connects to one that already runs, on this Mac's loopback
/// address only. This controller holds the chosen type and address, checks
/// the server now and then, lists its models, and says how to start one.
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

    /// What one look at the server found.
    enum Outcome: Equatable, Sendable {
        case ready(models: [ResearchServedModel], version: String?)
        case off(String)
        case problem(String)
    }

    public static let memoryNote =
        "On a Mac with 16 GB, run only one model server with a loaded model at a time."
    public static let keyNote =
        "The key was made by SandSeek and is sent with every request as a Bearer token. "
        + "That llama-server enforces --api-key (and so refuses requests without it) is "
        + "checked on the Mac in step 2b."

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
    /// The key SandSeek sends to llama.cpp.
    public let apiKey: String

    private let defaults: any ResearchSettingsStore
    private let transport: any ResearchHTTPTransport
    /// Whether TUFF's replies are read as a stream. On, as the plan says: that
    /// is what makes Stop reach a TUFF that has not been changed. The switch
    /// is the plan's way back to plain requests for a server that streams
    /// wrongly; llama.cpp is always plain for now (its connector is 2b).
    private let tuffStreaming: Bool
    @ObservationIgnored private var generation = 0

    public init(defaults: any ResearchSettingsStore = UserDefaults.standard,
                keyStore: any ResearchKeyStoring = FileKeyStore(),
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 3),
                tuffStreaming: Bool = true) {
        self.defaults = defaults
        self.transport = transport
        self.tuffStreaming = tuffStreaming
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

    private func resetStatus() {
        generation += 1
        state = .notChecked
        models = []
        connection = nil
        offReason = nil
    }

    /// The server address as an URL, only if it is an http address on this
    /// Mac's loopback interface. `127.0.0.1:8080` without a scheme is read as
    /// `http://127.0.0.1:8080`. A path other than `/v1` is refused.
    public nonisolated static func parseAddress(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        let url = try ResearchEndpoint.loopbackURL(text, flag: "The server address")
        guard url.path.isEmpty || url.path == "/v1" else {
            throw ResearchError.invalidEndpoint(
                "The server address must not have a path; use the address alone, such as "
                    + "http://127.0.0.1:8080")
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

    /// The command that starts a llama.cpp server SandSeek can use. It holds
    /// the key, so it is shown only on the connection card and copied on
    /// request. The port follows the address.
    public var startCommand: String? {
        guard serverType == .llamacpp else { return nil }
        let port = serverURL?.port ?? 8081
        return "llama-server -m <model.gguf> --alias <name> --host 127.0.0.1 --port \(port) "
            + "-c 16384 -np 1 --jinja --api-key \(apiKey)"
    }

    /// The hint for the chosen type, for when the server is off.
    public var startHint: String {
        switch serverType {
        case .tuff:
            "Start TUFF's Background API in its Server screen, or run `tuff serve`. "
                + "TUFF listens on 127.0.0.1:8080 unless you changed it."
        case .llamacpp:
            "Start llama.cpp with the command below. Replace <model.gguf> with your model "
                + "file and <name> with the name you want in the model list."
        case .ollama, .lmstudio:
            "\(serverType.displayName) support comes later."
        }
    }

    // MARK: - Looking at the server

    /// Looks at the server now and shows that it is looking. For the Check button.
    public func check() async {
        await look(showProgress: true)
    }

    /// Looks at the server again without changing what the card shows until
    /// the answer is in. For the periodic refresh.
    public func refresh() async {
        guard state != .checking else { return }
        await look(showProgress: false)
    }

    private func look(showProgress: Bool) async {
        let type = serverType
        let text = addressText
        guard let kind = type.kind else {
            state = .problem("\(type.displayName) support comes later.")
            return
        }
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
        generation += 1
        let mine = generation
        let outcome = await Self.inspect(
            kind: kind, url: url, authorization: Self.authorization(for: kind, key: apiKey),
            transport: transport)
        // The person changed the type or address meanwhile: this answer is old.
        guard mine == generation else { return }
        lastChecked = Date()
        switch outcome {
        case .ready(let listed, let version):
            models = listed
            connection = ResearchServerConnection(
                kind: kind, version: version, streaming: kind == .tuff && tuffStreaming)
            offReason = nil
            state = .ready
        case .off(let reason):
            models = []
            connection = nil
            offReason = reason
            state = .off
        case .problem(let message):
            models = []
            connection = nil
            offReason = nil
            state = .problem(message)
        }
    }

    /// Asks the server who it is and which models it lists. The chosen type
    /// must match what answers: a TUFF address that does not answer TUFF's
    /// status route, or a llama.cpp address that does, is reported as it is.
    nonisolated static func inspect(kind: ResearchServerKind,
                                    url: URL,
                                    authorization: String?,
                                    transport: any ResearchHTTPTransport) async -> Outcome {
        let probe = await ResearchServerConnection.probe(serverURL: url, transport: transport)
        var version: String?
        switch (kind, probe) {
        case (_, .unreachable(let reason)):
            return .off(reason)
        case (.tuff, .other(let status)):
            return .problem("A server answers at \(url.absoluteString), but not as TUFF "
                + "(HTTP \(status) from /tuff/v1/status). If it is llama.cpp, choose llama.cpp.")
        case (.llamacpp, .tuff):
            return .problem("A TUFF server answers at \(url.absoluteString), not llama.cpp. "
                + "Choose TUFF, or give llama.cpp another port.")
        case (.tuff, .tuff(let found)):
            version = found
        default:
            break
        }
        var base = url.absoluteString
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let modelsURL = URL(string: base + "/v1/models") else {
            return .problem("The server address cannot be extended to /v1/models.")
        }
        let response: ResearchHTTPResponse
        do {
            response = try await transport.send(
                method: "GET", url: modelsURL, body: nil, timeout: 5, authorization: authorization)
        } catch {
            return .off(error.localizedDescription)
        }
        switch response.status {
        case 200:
            break
        case 401, 403:
            return .problem("The server refused the key (HTTP \(response.status)). Start "
                + "llama-server again with the command below, so its --api-key is the one "
                + "SandSeek sends.")
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
        return .ready(models: list.data.map { ResearchServedModel(id: $0.id) }, version: version)
    }
}
