import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// An Ollama server for the app logic: `/api/version`, `/api/tags`,
/// `/api/show` and `/api/chat` from a script. Everything else (the sandbox)
/// goes to a `FakeResearchServices`, so a whole run can be played. It records
/// the requests it got, and what they carried in the `Authorization` slot.
private final class FakeOllamaServices: ResearchHTTPTransport, @unchecked Sendable {
    struct Seen: Equatable {
        let method: String
        let path: String
        let authorization: String?
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Seen] = []
    private var chatReplies: [ResearchHTTPResponse]
    let sandbox: FakeResearchServices
    private let version: ResearchHTTPResponse
    private let tags: ResearchHTTPResponse
    private let show: ResearchHTTPResponse

    init(version: ResearchHTTPResponse = ok(#"{"version":"0.40.2"}"#),
         tags: ResearchHTTPResponse = ok(FakeOllamaServices.tagsJSON(models: [
             FakeOllamaServices.model("qwen3:8b", capabilities: ["completion", "tools", "thinking"]),
         ])),
         show: ResearchHTTPResponse = ok(FakeOllamaServices.showJSON(
             capabilities: ["completion", "tools", "thinking"], context: 40_960)),
         chatReplies: [ResearchHTTPResponse] = [],
         sandbox: FakeResearchServices = FakeResearchServices(tuffStatus: false)) {
        self.version = version
        self.tags = tags
        self.show = show
        self.chatReplies = chatReplies
        self.sandbox = sandbox
    }

    var seen: [Seen] { lock.withLock { recorded } }
    var paths: [String] { seen.map(\.path) }
    var chatBodies: [ResearchJSON] {
        seen.filter { $0.path == "/api/chat" }.compactMap {
            try? ResearchJSON.decode(Data($0.body.utf8))
        }
    }

    private func answer(method: String, url: URL, body: Data?,
                        authorization: String?) async throws -> ResearchHTTPResponse? {
        guard url.path.hasPrefix("/api/") else { return nil }
        return lock.withLock {
            recorded.append(Seen(
                method: method, path: url.path, authorization: authorization,
                body: body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
            switch url.path {
            case "/api/version": return version
            case "/api/tags": return tags
            case "/api/show": return show
            case "/api/chat":
                guard !chatReplies.isEmpty else {
                    return ResearchHTTPResponse(status: 500, body: Data(#"{"error":"no reply scripted"}"#.utf8))
                }
                return chatReplies.removeFirst()
            default: return ResearchHTTPResponse(status: 404, body: Data())
            }
        }
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await send(method: method, url: url, body: body, timeout: nil, authorization: nil)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse {
        if let response = try await answer(
            method: method, url: url, body: body, authorization: authorization) {
            return response
        }
        return try await sandbox.send(
            method: method, url: url, body: body, timeout: timeout, authorization: authorization)
    }

    func sendStreaming(method: String, url: URL, body: Data?, timeout: TimeInterval?,
                       authorization: String?) async throws -> ResearchHTTPLineResponse {
        let response = try await send(
            method: method, url: url, body: body, timeout: timeout, authorization: authorization)
        return ResearchHTTPLineResponse(status: response.status, body: response.body)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        try await sandbox.send(
            method: method, url: url, body: body, timeout: timeout, authorization: authorization,
            headers: headers)
    }

    // MARK: scripts

    static func model(_ name: String, capabilities: [String]? = nil,
                      remoteHost: String? = nil) -> String {
        var fields = [#""name":"\#(name)""#, #""model":"\#(name)""#, #""size":4683075271"#]
        if let capabilities {
            fields.append(#""capabilities":[\#(capabilities.map { "\"\($0)\"" }.joined(separator: ","))]"#)
        }
        if let remoteHost {
            fields.append(#""remote_host":"\#(remoteHost)","remote_model":"upstream""#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static func tagsJSON(models: [String]) -> String {
        #"{"models":[\#(models.joined(separator: ","))]}"#
    }

    static func showJSON(capabilities: [String]?, context: Int?,
                         remoteHost: String? = nil) -> String {
        var fields: [String] = []
        if let capabilities {
            fields.append(#""capabilities":[\#(capabilities.map { "\"\($0)\"" }.joined(separator: ","))]"#)
        }
        if let remoteHost { fields.append(#""remote_host":"\#(remoteHost)""#) }
        let info = context.map {
            #"{"general.architecture":"qwen3","qwen3.context_length":\#($0),"qwen3.embedding_length":4096}"#
        } ?? "{}"
        fields.append(#""model_info":\#(info)"#)
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// A finished turn with text.
    static func text(_ content: String) -> ResearchHTTPResponse {
        let message = try! ResearchJSON.object([
            "role": .string("assistant"), "content": .string(content),
        ]).encoded()
        return ok(#"{"model":"qwen3:8b","message":\#(String(decoding: message, as: UTF8.self)),"done":true,"done_reason":"stop","prompt_eval_count":120}"#)
    }

    /// A finished turn with one tool call whose arguments are an object.
    static func call(_ name: String, _ arguments: ResearchJSON) -> ResearchHTTPResponse {
        let message = try! ResearchJSON.object([
            "role": .string("assistant"), "content": .string(""),
            "tool_calls": .array([.object([
                "id": .string("call_\(name)"),
                "function": .object([
                    "index": .integer(0), "name": .string(name), "arguments": arguments,
                ]),
            ])]),
        ]).encoded()
        return ok(#"{"model":"qwen3:8b","message":\#(String(decoding: message, as: UTF8.self)),"done":true,"done_reason":"stop","prompt_eval_count":120}"#)
    }
}

private func ok(_ json: String) -> ResearchHTTPResponse {
    ResearchHTTPResponse(status: 200, body: Data(json.utf8))
}

private final class NothingListens: ResearchHTTPTransport, @unchecked Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}

@Suite @MainActor struct ResearchOllamaServerControllerTests {
    private func controller(
        _ services: any ResearchHTTPTransport,
        exposureCheck: (@Sendable (Int) async -> ResearchExposureReport)? = nil
    ) -> ResearchServerController {
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "test-key"),
            transport: services, exposureCheck: exposureCheck)
        server.select(.ollama)
        return server
    }

    @Test func theCardListsOnlyLocalModelsThatCanCallTools() async {
        let tags = FakeOllamaServices.tagsJSON(models: [
            FakeOllamaServices.model("qwen3:8b", capabilities: ["completion", "tools", "thinking"]),
            FakeOllamaServices.model("qwen2.5-coder:1.5b-base", capabilities: ["completion"]),
            FakeOllamaServices.model("nomic-embed-text:latest", capabilities: ["embedding"]),
            FakeOllamaServices.model("gpt-oss:120b", capabilities: ["completion", "tools"],
                                     remoteHost: "https://ollama.com:443"),
            FakeOllamaServices.model("kimi-k2:cloud", capabilities: ["completion", "tools"]),
            FakeOllamaServices.model("qwen3-coder:480b-cloud", capabilities: ["tools"]),
            // An older Ollama lists no capabilities: kept.
            FakeOllamaServices.model("llama3.1:8b"),
            // The same name twice would collide in the picker.
            FakeOllamaServices.model("qwen3:8b", capabilities: ["tools"]),
        ])
        let services = FakeOllamaServices(tags: ok(tags))
        let server = controller(services)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.models.map(\.id) == ["qwen3:8b", "llama3.1:8b"])
        #expect(server.connection?.kind == .ollama)
        #expect(server.connection?.version == "0.40.2")
        #expect(server.connection?.streaming == true)
        // The window is chosen per model when a question starts.
        #expect(server.connection?.contextTokens == nil)
        #expect(services.paths == ["/api/version", "/api/tags"])
        // Ollama has no key: nothing is sent in the Authorization slot.
        #expect(services.seen.allSatisfy { $0.authorization == nil })
        #expect(server.authorization == nil)
        #expect(!server.needsPromptBudget)
    }

    @Test func ollamaIsNotAskedTheOtherServersRoutes() async {
        let services = FakeOllamaServices()
        let server = controller(services)
        await server.check()
        // Neither /v1/models nor TUFF's status route is asked.
        #expect(!services.paths.contains("/v1/models"))
        #expect(!services.paths.contains("/tuff/v1/status"))
    }

    @Test func onlyCloudModelsGiveAProblemThatSaysWhy() async {
        let tags = FakeOllamaServices.tagsJSON(models: [
            FakeOllamaServices.model("gpt-oss:120b", capabilities: ["tools"],
                                     remoteHost: "https://ollama.com:443"),
            FakeOllamaServices.model("kimi-k2:cloud", capabilities: ["tools"]),
        ])
        let server = controller(FakeOllamaServices(tags: ok(tags)))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("cloud models are not used"), "\(message)")
        #expect(message.contains("leave this Mac"), "\(message)")
        #expect(message.contains("ollama pull"), "\(message)")
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)
    }

    @Test func modelsThatCannotCallToolsGiveAProblemThatSaysWhy() async {
        let tags = FakeOllamaServices.tagsJSON(models: [
            FakeOllamaServices.model("qwen2.5-coder:1.5b-base", capabilities: ["completion"]),
            FakeOllamaServices.model("nomic-embed-text:latest", capabilities: ["embedding"]),
        ])
        let server = controller(FakeOllamaServices(tags: ok(tags)))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("no installed model can call tools"), "\(message)")
        #expect(message.contains("ollama pull"), "\(message)")
        #expect(!message.contains("cloud models"), "\(message)")
    }

    @Test func noModelAtAllIsAProblemToo() async {
        let server = controller(FakeOllamaServices(tags: ok(#"{"models":[]}"#)))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("no model installed"), "\(message)")
        #expect(message.contains("ollama pull"), "\(message)")
    }

    @Test func aTagsAnswerThatIsNotAListIsAProblem() async {
        for tags in [ok("<html>"), ok(#"{"models":"none"}"#),
                     ResearchHTTPResponse(status: 500, body: Data())] {
            let server = controller(FakeOllamaServices(tags: tags))
            await server.check()
            guard case .problem = server.state else {
                Issue.record("expected a problem, got \(server.state)")
                continue
            }
            #expect(server.models.isEmpty)
        }
    }

    @Test func nothingListeningIsOffNotAProblem() async {
        let server = controller(NothingListens())
        await server.check()
        #expect(server.state == .off)
        #expect(server.offReason != nil)
    }

    @Test func aRedirectIsReportedAndNeverFollowed() async {
        let server = controller(FakeOllamaServices(
            version: ResearchHTTPResponse(status: 302, body: Data())))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("redirect"), "\(message)")
    }

    @Test func aTuffServerAtTheOllamaAddressIsNamed() async {
        let server = controller(FakeResearchServices())
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("TUFF server answers"), "\(message)")
        #expect(message.contains("not Ollama"), "\(message)")
    }

    @Test func aLlamaCppServerAtTheOllamaAddressIsNotOllama() async {
        let server = controller(FakeResearchServices(tuffStatus: false, llamaContext: 8192))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("not as Ollama"), "\(message)")
        #expect(message.contains("/api/version"), "\(message)")
    }

    @Test func anOllamaServerAtAnotherTypesAddressIsNamed() async {
        let services = FakeOllamaServices()
        let tuff = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"), transport: services)
        await tuff.check()
        guard case .problem(let tuffMessage) = tuff.state else {
            Issue.record("expected a problem, got \(tuff.state)")
            return
        }
        #expect(tuffMessage.contains("Ollama server answers"), "\(tuffMessage)")
        #expect(tuffMessage.contains("not TUFF"), "\(tuffMessage)")

        let llama = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"), transport: services)
        llama.select(.llamacpp)
        await llama.check()
        guard case .problem(let llamaMessage) = llama.state else {
            Issue.record("expected a problem, got \(llama.state)")
            return
        }
        #expect(llamaMessage.contains("does not look like llama.cpp"), "\(llamaMessage)")
        #expect(llamaMessage.contains("Ollama"), "\(llamaMessage)")
        // The old text said Ollama was not supported.
        #expect(!llamaMessage.contains("Ollama and LM Studio are not supported"), "\(llamaMessage)")
    }

    @Test func theQuickLookAsksOnlyTheVersionRoute() async {
        let url = URL(string: "http://127.0.0.1:11434")!
        let services = FakeOllamaServices()
        #expect(await ResearchServerController.quickLook(
            kind: .ollama, url: url, transport: services) == .alive)
        #expect(services.paths == ["/api/version"])
        #expect(await ResearchServerController.quickLook(
            kind: .ollama, url: url, transport: FakeResearchServices()) == .changed)
        let gone = await ResearchServerController.quickLook(
            kind: .ollama, url: url, transport: NothingListens())
        guard case .gone = gone else {
            Issue.record("expected gone, got \(gone)")
            return
        }
    }

    @Test func pollingAReadyOllamaDoesNotListTheModelsAgain() async {
        let services = FakeOllamaServices()
        let server = controller(services)
        await server.check()
        #expect(services.paths == ["/api/version", "/api/tags"])
        await server.refresh()
        await server.refresh()
        #expect(server.state == .ready)
        #expect(services.paths == ["/api/version", "/api/tags", "/api/version", "/api/version"])
    }

    @Test func theExposureWarningGivesOllamasAdvice() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let report = ResearchExposureReport(
            port: 11_434, loopbackAnswered: true, checked: [lan], reachable: [lan])
        let server = controller(FakeOllamaServices(), exposureCheck: { _ in report })
        await server.check()
        guard case .reachable(let warning) = server.exposure else {
            Issue.record("expected a warning, got \(server.exposure)")
            return
        }
        #expect(warning.contains("OLLAMA_HOST=127.0.0.1:11434"), "\(warning)")
        #expect(!warning.contains("0.0.0.0"), "\(warning)")
        // The same report for TUFF keeps the old advice.
        let tuff = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
            transport: FakeResearchServices(), exposureCheck: { _ in report })
        await tuff.check()
        guard case .reachable(let tuffWarning) = tuff.exposure else {
            Issue.record("expected a warning, got \(tuff.exposure)")
            return
        }
        #expect(tuffWarning.contains("llama-server: --host 127.0.0.1"), "\(tuffWarning)")
    }

    @Test func theOllamaAddressIsRememberedLikeTheOthers() {
        let settings = MemorySettings()
        let first = ResearchServerController(
            defaults: settings, keyStore: MemoryKeyStore(key: "k"),
            transport: FakeOllamaServices())
        first.select(.ollama)
        first.setAddress("http://127.0.0.1:11500")
        let second = ResearchServerController(
            defaults: settings, keyStore: MemoryKeyStore(key: "k"),
            transport: FakeOllamaServices())
        #expect(second.serverType == .ollama)
        #expect(second.addressText == "http://127.0.0.1:11500")
        second.restoreDefaultAddress()
        #expect(second.addressText == "http://127.0.0.1:11434")
    }
}

/// Ollama that is not there until `open()` is called, as before `ollama serve`
/// runs. Everything is then answered by the scripted Ollama.
private final class GatedOllama: ResearchHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    let inner = FakeOllamaServices()

    init(open: Bool = false) { isOpen = open }

    func open() { lock.withLock { isOpen = true } }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        if !lock.withLock({ isOpen }) { throw URLError(.cannotConnectToHost) }
        return try await inner.send(method: method, url: url, body: body)
    }
}

@Suite @MainActor struct ResearchOllamaLaunchTests {
    private static let fast = ResearchServerLaunchController.Timing(
        poll: .milliseconds(5), tuffReady: .seconds(5), llamaReady: .seconds(5),
        stopGrace: .milliseconds(150), killGrace: .milliseconds(150))

    private struct Rig {
        let launch: ResearchServerLaunchController
        let server: ResearchServerController
        let launcher: FakeServerLauncher
        let ollama: GatedOllama
        let stateDirectory: URL
        var markerExists: Bool { ResearchServerMarker.load(from: stateDirectory) != nil }
    }

    /// A card with Ollama chosen and a program chosen, a fake launcher, and an
    /// Ollama that answers once the launcher has started it (unless `answering`
    /// from the start).
    private func makeRig(program: String? = "/opt/homebrew/bin/ollama",
                         answering: Bool = false, exposed: Bool = false) -> Rig {
        let ollama = GatedOllama(open: answering)
        let settings = MemorySettings()
        if let program { settings.save(program, forKey: "ResearchServerProgram-ollama") }
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: nil), transport: ollama,
            exposureCheck: { port in
                ResearchExposureReport(
                    port: port, loopbackAnswered: true,
                    checked: [.ipv4(192, 168, 1, 5)], reachable: exposed ? [.ipv4(192, 168, 1, 5)] : [])
            })
        server.select(.ollama)
        let launcher = FakeServerLauncher()
        let hooked = HookedLauncher(inner: launcher, after: { ollama.open() })
        let state = temporaryDirectory("SandSeekOllamaState")
        let launch = testLaunchController(
            settings: settings, launcher: hooked, transport: ollama,
            stateDirectory: state, timing: ResearchOllamaLaunchTests.fast)
        return Rig(launch: launch, server: server, launcher: launcher, ollama: ollama,
                   stateDirectory: state)
    }

    @Test func ollamaCanBeStartedWithoutAModel() {
        #expect(ResearchServerType.ollama.canStart)
        let rig = makeRig()
        #expect(rig.launch.startBlocker(for: rig.server) == nil)
        let none = makeRig(program: nil)
        #expect(none.launch.startBlocker(for: none.server) == "Choose the program first.")
    }

    @Test func startRunsOllamaServeAndWaitsForTheVersionRoute() async {
        let rig = makeRig()
        await rig.launch.start(using: rig.server)
        #expect(rig.launch.state == .running)
        #expect(rig.launcher.plans.count == 1)
        let plan = rig.launcher.plans[0]
        #expect(plan.executable == "/opt/homebrew/bin/ollama")
        #expect(plan.arguments == ["serve"])
        #expect(plan.environment["OLLAMA_HOST"] == "127.0.0.1:11434")
        #expect(plan.environment["OLLAMA_NO_CLOUD"] == "1")
        #expect(Set(plan.environment.keys)
            == ["PATH", "HOME", "TMPDIR", "OLLAMA_HOST", "OLLAMA_NO_CLOUD"])
        // The version route answered, then the normal Check ran.
        #expect(rig.ollama.inner.paths.first == "/api/version")
        #expect(rig.server.state == .ready)
        #expect(rig.launch.owned?.type == .ollama)
        #expect(rig.launch.owned?.port == 11_434)
        #expect(rig.markerExists)
    }

    @Test func startIsRefusedWhenSomethingAlreadyListensOnThePort() async {
        let rig = makeRig(answering: true)
        await rig.launch.start(using: rig.server)
        guard case .failed(let message) = rig.launch.state else {
            Issue.record("expected the start to fail, got \(rig.launch.state)")
            return
        }
        #expect(message.contains("already answers on 127.0.0.1:11434"), "\(message)")
        #expect(message.contains("Ollama menu-bar app"), "\(message)")
        #expect(rig.launcher.plans.isEmpty)
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func anOllamaReachableFromTheNetworkIsStopped() async {
        let rig = makeRig(exposed: true)
        await rig.launch.start(using: rig.server)
        guard case .failed(let message) = rig.launch.state else {
            Issue.record("expected the start to fail, got \(rig.launch.state)")
            return
        }
        #expect(message.contains("Another program may be listening"), "\(message)")
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func stopEndsOnlyTheOllamaSandSeekStarted() async {
        let rig = makeRig()
        // Nothing started by SandSeek: Stop does nothing.
        await rig.launch.stop(using: rig.server)
        #expect(rig.launcher.servers.isEmpty)
        await rig.launch.start(using: rig.server)
        #expect(rig.launch.owned?.type == .ollama)
        await rig.launch.stop(using: rig.server)
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.state == .idle)
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func aProgramPickMustBeCalledOllamaOrBeOllamaApp() {
        let launch = testLaunchController()
        launch.chooseProgram("/opt/homebrew/bin/ollama", for: .ollama)
        #expect(launch.programs[.ollama] == "/opt/homebrew/bin/ollama")
        #expect(launch.choiceProblem == nil)
        launch.chooseProgram("/bin/sh", for: .ollama)
        #expect(launch.choiceProblem?.contains("ollama") == true)
        #expect(launch.programs[.ollama] == "/opt/homebrew/bin/ollama")
    }

    @Test func noModelCanBeChosenForOllama() {
        // A saved llama.cpp model is not read as Ollama's.
        let settings = MemorySettings()
        settings.save("/x/model.gguf", forKey: "ResearchServerModel-llamacpp")
        let launch = testLaunchController(settings: settings)
        #expect(launch.models[.ollama] == nil)
        #expect(launch.models[.llamacpp] == "/x/model.gguf")
        launch.chooseModel("/tmp", for: .ollama)
        #expect(launch.models[.ollama] == nil)
        #expect(launch.choiceProblem == nil)
    }

    @Test func aLeftoverOllamaThatMatchesIsTakenOverNotStopped() throws {
        let state = temporaryDirectory("SandSeekOllamaMarker")
        let identity = ResearchProcessIdentity(
            startSeconds: 1_000, startMicroseconds: 7, path: "/opt/homebrew/bin/ollama")
        try ResearchServerMarker(type: "ollama", port: 11_434, pid: 41_000, identity: identity)
            .write(to: state)
        let launch = testLaunchController(stateDirectory: state, identityOf: { _ in identity })
        #expect(launch.owned?.type == .ollama)
        #expect(launch.owned?.adopted == true)
        #expect(launch.state == .running)
    }

    @Test func aMarkerThatDoesNotMatchIsDeleted() throws {
        let state = temporaryDirectory("SandSeekOllamaMarker")
        let identity = ResearchProcessIdentity(
            startSeconds: 1_000, startMicroseconds: 7, path: "/opt/homebrew/bin/ollama")
        try ResearchServerMarker(type: "ollama", port: 11_434, pid: 41_000, identity: identity)
            .write(to: state)
        let launch = testLaunchController(stateDirectory: state, identityOf: { _ in nil })
        #expect(launch.owned == nil)
        #expect(ResearchServerMarker.load(from: state) == nil)

        // The process id now belongs to a process that started at another time.
        try ResearchServerMarker(type: "ollama", port: 11_434, pid: 41_000, identity: identity)
            .write(to: state)
        let reused = ResearchProcessIdentity(
            startSeconds: 2_000, startMicroseconds: 7, path: "/opt/homebrew/bin/ollama")
        let other = testLaunchController(stateDirectory: state, identityOf: { _ in reused })
        #expect(other.owned == nil)
        #expect(ResearchServerMarker.load(from: state) == nil)
    }

    @Test func lmStudioStillCannotBeStarted() {
        #expect(ResearchServerType.allCases.filter(\.canStart) == [.tuff, .llamacpp, .ollama])
    }
}

@Suite @MainActor struct ResearchOllamaRunTests {
    private let serverURL = URL(string: "http://127.0.0.1:11434")!
    private let sandboxURL = URL(string: "http://127.0.0.1:9100")!
    private let connection = ResearchServerConnection(kind: .ollama, version: "0.40.2", streaming: true)

    private func controller(_ services: FakeOllamaServices) -> ResearchRunController {
        ResearchRunController(
            store: ResearchReportStore(directory: temporaryDirectory()),
            transport: services, sandboxSecretFile: TestSandboxSecret.file)
    }

    @Test func aRunPassesTheOllamaConnectionAndTheContextAndIsSavedAsOllama() async throws {
        let services = FakeOllamaServices(chatReplies: [
            FakeOllamaServices.call(
                "open_page", .object(["url": .string("https://github.com/apple/container")])),
            FakeOllamaServices.text("From the page [1]."),
            FakeOllamaServices.text("From the page [1]."),
        ])
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(model: "qwen3:8b", showThinking: false),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        #expect(run.phase == .finished)
        #expect(run.report?.serverKind == "ollama")
        #expect(run.report?.serverDisplayName == "Ollama")

        // The model was checked once, then every chat went to /api/chat.
        #expect(services.paths.filter { $0 == "/api/show" }.count == 1)
        #expect(services.paths.first == "/api/show")
        #expect(!services.paths.contains("/v1/chat/completions"))
        let show = try #require(services.seen.first)
        #expect(try ResearchJSON.decode(Data(show.body.utf8)) == .object(["model": .string("qwen3:8b")]))
        let bodies = services.chatBodies
        #expect(bodies.count >= 2)
        for body in bodies {
            // The model's trained maximum is 40,960; the window is 32,768.
            #expect(body["options"]?["num_ctx"] == ResearchJSON.integer(32_768))
            #expect(body["model"] == ResearchJSON.string("qwen3:8b"))
            #expect(body["truncate"] == ResearchJSON.bool(false))
            #expect(body["stream"] == ResearchJSON.bool(true))
            #expect(body["enable_thinking"] == nil)
        }
        // The thinking switch was left alone and the model can think: `think`
        // is sent as false, so that Ollama's own default (on) does not apply.
        #expect(bodies.first?["think"] == ResearchJSON.bool(false))
        // Ollama is never sent a key.
        #expect(services.seen.allSatisfy { $0.authorization == nil })
    }

    @Test func theThinkingSwitchBecomesThink() async {
        for (setting, expected) in [(true, ResearchJSON.bool(true)), (false, ResearchJSON.bool(false))] {
            let services = FakeOllamaServices(chatReplies: [
                FakeOllamaServices.call(
                    "open_page", .object(["url": .string("https://github.com/apple/container")])),
                FakeOllamaServices.text("From the page [1]."),
                FakeOllamaServices.text("From the page [1]."),
            ])
            let run = controller(services)
            run.start(question: "Anything about https://github.com/apple/container",
                      settings: ResearchRunSettings(model: "qwen3:8b", thinking: setting),
                      serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
            await waitUntil { !run.isRunning }
            let first = services.chatBodies.first
            #expect(first?["think"] == expected, "thinking \(setting)")
        }
    }

    @Test func aModelThatCannotThinkIsNeverSentThink() async {
        for setting in [true, false] {
            let services = FakeOllamaServices(
                show: ok(FakeOllamaServices.showJSON(
                    capabilities: ["completion", "tools"], context: 40_960)),
                chatReplies: [
                    FakeOllamaServices.call(
                        "open_page", .object(["url": .string("https://github.com/apple/container")])),
                    FakeOllamaServices.text("From the page [1]."),
                    FakeOllamaServices.text("From the page [1]."),
                ])
            let run = controller(services)
            run.start(question: "Anything about https://github.com/apple/container",
                      settings: ResearchRunSettings(model: "qwen3:8b", thinking: setting),
                      serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
            await waitUntil { !run.isRunning }
            #expect(run.phase == .finished, "thinking \(setting)")
            let bodies = services.chatBodies
            #expect(!bodies.isEmpty)
            for body in bodies { #expect(body["think"] == nil, "thinking \(setting)") }
        }
    }

    @Test func theContextCanBeSetInTheSettings() async {
        let services = FakeOllamaServices(chatReplies: [
            FakeOllamaServices.call(
                "open_page", .object(["url": .string("https://github.com/apple/container")])),
            FakeOllamaServices.text("From the page [1]."),
            FakeOllamaServices.text("From the page [1]."),
        ])
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(
                      model: "qwen3:8b", showThinking: false, ollamaContextTokens: 16_384),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        #expect(services.chatBodies.first?["options"]?["num_ctx"] == ResearchJSON.integer(16_384))
    }

    @Test func aSettingAboveTheModelsMaximumIsLoweredToIt() async {
        let services = FakeOllamaServices(chatReplies: [
            FakeOllamaServices.call(
                "open_page", .object(["url": .string("https://github.com/apple/container")])),
            FakeOllamaServices.text("From the page [1]."),
            FakeOllamaServices.text("From the page [1]."),
        ])
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(
                      model: "qwen3:8b", showThinking: false, ollamaContextTokens: 65_536),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        // The trained maximum of the fake model is 40,960.
        #expect(services.chatBodies.first?["options"]?["num_ctx"] == ResearchJSON.integer(40_960))
    }

    @Test func theSettingsKeepTheContextInsideTheCommandsRange() {
        #expect(ResearchRunSettings(model: "m").ollamaContextTokens == nil)
        #expect(ResearchRunSettings(model: "m", ollamaContextTokens: 100).ollamaContextTokens == 4_096)
        #expect(ResearchRunSettings(model: "m", ollamaContextTokens: 9_999_999)
            .ollamaContextTokens == 262_144)
        #expect(ResearchRunSettings(model: "m", ollamaContextTokens: 16_384)
            .ollamaContextTokens == 16_384)
    }

    @Test func aCloudModelEndsTheRunBeforeAnyRequestAndSavesNothing() async {
        let services = FakeOllamaServices()
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(model: "gpt-oss:120b-cloud"),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        guard case .failed(let message) = run.phase else {
            Issue.record("expected the run to fail, got \(run.phase)")
            return
        }
        #expect(message.contains("runs on ollama.com"), "\(message)")
        #expect(services.seen.isEmpty)
        #expect(run.report == nil)
    }

    @Test func aModelThatOllamaRunsRemotelyEndsTheRun() async {
        let services = FakeOllamaServices(show: ok(FakeOllamaServices.showJSON(
            capabilities: ["tools"], context: 8192, remoteHost: "https://ollama.com:443")))
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(model: "alias"),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        guard case .failed(let message) = run.phase else {
            Issue.record("expected the run to fail, got \(run.phase)")
            return
        }
        #expect(message.contains("keeps your question on this Mac"), "\(message)")
        #expect(services.chatBodies.isEmpty)
    }

    @Test func aModelWithoutToolsEndsTheRun() async {
        let services = FakeOllamaServices(show: ok(FakeOllamaServices.showJSON(
            capabilities: ["completion"], context: 8192)))
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(model: "qwen2.5-coder:1.5b-base"),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        guard case .failed(let message) = run.phase else {
            Issue.record("expected the run to fail, got \(run.phase)")
            return
        }
        #expect(message.contains("cannot call tools"), "\(message)")
        #expect(services.chatBodies.isEmpty)
    }

    @Test func aModelThatIsNotInstalledEndsTheRunWithHowToGetIt() async {
        let services = FakeOllamaServices(show: ResearchHTTPResponse(
            status: 404, body: Data(#"{"error":"model 'nope' not found"}"#.utf8)))
        let run = controller(services)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(model: "nope:7b"),
                  serverURL: serverURL, sandboxURL: sandboxURL, connection: connection)
        await waitUntil { !run.isRunning }
        guard case .failed(let message) = run.phase else {
            Issue.record("expected the run to fail, got \(run.phase)")
            return
        }
        #expect(message.contains("ollama pull nope:7b"), "\(message)")
    }

    @Test func aTuffRunAsksOllamaNothing() async {
        let services = FakeOllamaServices()
        let sandboxServices = services.sandbox
        let run = ResearchRunController(
            store: ResearchReportStore(directory: temporaryDirectory()),
            transport: sandboxServices, sandboxSecretFile: TestSandboxSecret.file)
        run.start(question: "Anything about https://github.com/apple/container",
                  settings: ResearchRunSettings(model: "m"),
                  serverURL: URL(string: "http://127.0.0.1:8080")!, sandboxURL: sandboxURL)
        await waitUntil { !run.isRunning }
        #expect(services.seen.isEmpty)
        #expect(!sandboxServices.paths.contains("/api/show"))
    }
}
