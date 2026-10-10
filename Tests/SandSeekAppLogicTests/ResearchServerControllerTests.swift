import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// A model server that nothing listens on.
private final class NothingListens: ResearchHTTPTransport, @unchecked Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}

/// Answers like TUFF, but holds every request until `release()`, so a test can
/// change the address while a look is under way.
private final class SlowServices: ResearchHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    private var released = false
    private let inner = FakeResearchServices()

    func waitUntilAsked() async {
        while !lock.withLock({ asked }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() { lock.withLock { released = true } }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        lock.withLock { asked = true }
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
        return try await inner.send(method: method, url: url, body: body)
    }
}

/// A server whose every request runs out of time.
private final class TimedOutServices: ResearchHTTPTransport, @unchecked Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        throw URLError(.timedOut)
    }
}

/// A server that is not TUFF and answers `/props` with a fixed text.
private final class FixedPropsServices: ResearchHTTPTransport, @unchecked Sendable {
    let text: String

    init(body text: String) { self.text = text }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        url.path == "/props"
            ? ResearchHTTPResponse(status: 200, body: Data(text.utf8))
            : ResearchHTTPResponse(status: 404, body: Data())
    }
}

@Suite @MainActor struct ResearchServerControllerTests {
    private func controller(
        services: any ResearchHTTPTransport = FakeResearchServices(),
        settings: MemorySettings = MemorySettings(),
        keys: MemoryKeyStore = MemoryKeyStore(key: "test-key")
    ) -> ResearchServerController {
        ResearchServerController(defaults: settings, keyStore: keys, transport: services)
    }

    // MARK: types and defaults

    @Test func theTypesHaveTheirDefaultAddresses() {
        #expect(ResearchServerType.tuff.defaultAddress == "http://127.0.0.1:8080")
        #expect(ResearchServerType.llamacpp.defaultAddress == "http://127.0.0.1:8081")
        #expect(ResearchServerType.ollama.defaultAddress == nil)
        #expect(ResearchServerType.lmstudio.defaultAddress == nil)
        #expect(ResearchServerType.tuff.kind == .tuff)
        #expect(ResearchServerType.llamacpp.kind == .llamacpp)
        #expect(ResearchServerType.ollama.kind == nil)

        let server = controller()
        #expect(server.serverType == .tuff)
        #expect(server.addressText == "http://127.0.0.1:8080")
        #expect(server.state == .notChecked)
        server.select(.llamacpp)
        #expect(server.serverType == .llamacpp)
        #expect(server.addressText == "http://127.0.0.1:8081")
    }

    @Test func ollamaAndLMStudioAreShownButCannotBeChosen() {
        #expect(ResearchServerType.allCases.map(\.displayName)
            == ["TUFF", "llama.cpp", "Ollama", "LM Studio"])
        #expect(ResearchServerType.allCases.filter { !$0.isAvailable } == [.ollama, .lmstudio])
        #expect(ResearchServerType.ollama.pickerLabel == "Ollama (later)")
        #expect(ResearchServerType.lmstudio.pickerLabel == "LM Studio (later)")
        #expect(ResearchServerType.tuff.pickerLabel == "TUFF")
        let server = controller()
        server.select(.ollama)
        server.select(.lmstudio)
        #expect(server.serverType == .tuff)
    }

    @Test func theChoiceAndEachTypesAddressAreRemembered() {
        let settings = MemorySettings()
        let first = controller(settings: settings)
        first.select(.llamacpp)
        first.setAddress("http://127.0.0.1:9090")
        first.select(.tuff)
        first.setAddress("127.0.0.1:8181")
        first.select(.llamacpp)
        #expect(first.addressText == "http://127.0.0.1:9090")

        let second = controller(settings: settings)
        #expect(second.serverType == .llamacpp)
        #expect(second.addressText == "http://127.0.0.1:9090")
        second.select(.tuff)
        #expect(second.addressText == "127.0.0.1:8181")
        second.restoreDefaultAddress()
        #expect(second.addressText == "http://127.0.0.1:8080")
    }

    @Test func aStoredTypeThatComesLaterFallsBackToTuff() {
        let settings = MemorySettings()
        settings.save("ollama", forKey: ResearchServerController.typeKey)
        #expect(controller(settings: settings).serverType == .tuff)
        settings.save("nonsense", forKey: ResearchServerController.typeKey)
        #expect(controller(settings: settings).serverType == .tuff)
    }

    // MARK: loopback only

    @Test func onlyLoopbackAddressesAreAccepted() throws {
        for text in ["http://127.0.0.1:8080", "127.0.0.1:8080", "http://localhost:8080",
                     "localhost:8081", "http://[::1]:8080", "http://127.0.0.1:8080/",
                     "http://127.0.0.1:8080/v1", "  http://127.0.0.1:8080  "] {
            #expect(throws: Never.self) { _ = try ResearchServerController.parseAddress(text) }
        }
        #expect(try ResearchServerController.parseAddress("127.0.0.1:8080").absoluteString
            == "http://127.0.0.1:8080")
        #expect(try ResearchServerController.parseAddress("http://127.0.0.1:8080/").absoluteString
            == "http://127.0.0.1:8080")
    }

    @Test func anAddressNeedsAPortAndNotTheSandboxsPort() {
        #expect(throws: ResearchError.self) {
            _ = try ResearchServerController.parseAddress("http://127.0.0.1")
        }
        #expect(throws: ResearchError.self) {
            _ = try ResearchServerController.parseAddress("localhost")
        }
        // The key would go to the sandbox, which reaches the internet.
        #expect(throws: ResearchError.self) {
            _ = try ResearchServerController.parseAddress("http://127.0.0.1:9100")
        }
        #expect(ResearchServerController.sandboxPort == ResearchSandboxController.port)
    }

    @Test func otherAddressesAreRefused() {
        for text in ["http://192.168.1.5:8080", "http://10.0.0.2:8080", "http://example.com",
                     "https://127.0.0.1:8080", "http://127.0.0.1.example.com:8080",
                     "http://0.0.0.0:8080", "http://user@127.0.0.1:8080",
                     "http://127.0.0.1:8080?x=1", "ftp://127.0.0.1", "", "   ",
                     "http://127.0.0.1:8080/api", "http://[fe80::1]:8080"] {
            #expect(throws: ResearchError.self, "\(text)") {
                _ = try ResearchServerController.parseAddress(text)
            }
        }
    }

    @Test func aRefusedAddressIsReportedAndNothingIsSent() async {
        let services = FakeResearchServices()
        let server = controller(services: services)
        server.setAddress("http://192.168.1.5:8080")
        #expect(server.serverURL == nil)
        #expect(server.addressProblem?.contains("127.0.0.1") == true)
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("127.0.0.1"))
        #expect(services.paths.isEmpty)
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)
    }

    // MARK: looking at a TUFF server

    @Test func aTuffServerIsReadyWithItsModels() async {
        let services = FakeResearchServices(listedModels: ["qwen3.6-35b-a3b", "gemma-4-e4b-it"])
        let server = controller(services: services)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.models.map(\.id) == ["qwen3.6-35b-a3b", "gemma-4-e4b-it"])
        #expect(server.connection?.kind == .tuff)
        #expect(server.connection?.version == "8.3.1")
        #expect(server.connection?.streaming == true)
        #expect(server.authorization == nil)
        #expect(server.lastChecked != nil)
        // TUFF is asked without any key.
        #expect(services.authorizations.allSatisfy { $0.value == nil })
    }

    @Test func theStreamingSwitchGivesTuffPlainRequests() async {
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
            transport: FakeResearchServices(), tuffStreaming: false)
        await server.check()
        #expect(server.connection?.kind == .tuff)
        #expect(server.connection?.streaming == false)
    }

    @Test func aServerThatIsNotTuffIsNamedAsSuch() async {
        let server = controller(services: FakeResearchServices(tuffStatus: false))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("not as TUFF"))
        #expect(server.models.isEmpty)
    }

    @Test func nothingListeningMeansOff() async {
        let server = controller(services: NothingListens())
        server.setAddress("http://127.0.0.1:8080")
        await server.check()
        #expect(server.state == .off)
        #expect(server.offReason != nil)
        #expect(server.connection == nil)
    }

    @Test func aServerThatGoesAwayTurnsOffOnTheNextRefresh() async {
        let services = FakeResearchServices()
        let server = controller(services: services)
        await server.refresh()
        #expect(server.state == .ready)
        #expect(!server.models.isEmpty)

        services.setDown(true)
        await server.refresh()
        #expect(server.state == .off)
        #expect(server.offReason != nil)
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)

        // It comes back: the next refresh looks at it in full.
        services.setDown(false)
        await server.refresh()
        #expect(server.state == .ready)
        #expect(!server.models.isEmpty)
    }

    @Test func aReadyServerIsOnlyAskedItsStatusRouteWhenPolled() async {
        let services = FakeResearchServices()
        let server = controller(services: services)
        await server.check()
        #expect(server.state == .ready)
        services.clearPaths()

        await server.refresh()
        await server.refresh()
        #expect(services.paths == ["/tuff/v1/status", "/tuff/v1/status"])
        #expect(server.state == .ready)

        // The model list is fetched again on request only.
        await server.refreshModels()
        #expect(services.paths.contains("/v1/models"))
    }

    @Test func aReadyLlamaCppServerIsOnlyAskedHealthWhenPolled() async {
        let services = FakeResearchServices(
            tuffStatus: false, requiredKey: "test-key", llamaContext: 8192)
        let server = controller(services: services)
        server.select(.llamacpp)
        await server.check()
        #expect(server.state == .ready)
        services.clearPaths()

        await server.refresh()
        #expect(services.paths == ["/health"])
        #expect(server.state == .ready)
    }

    @Test func aServerThatChangedUnderAReadyCardIsLookedAtInFull() async {
        let services = FakeResearchServices()
        let server = controller(services: services)
        await server.check()
        #expect(server.state == .ready)
        // The status route now answers something that is not TUFF's.
        services.setTuffStatus(false)
        await server.refresh()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("not as TUFF"))
        #expect(server.models.isEmpty)
        // A problem is looked at in full again on each refresh, so it clears.
        services.setTuffStatus(true)
        await server.refresh()
        #expect(server.state == .ready)
    }

    @Test func aStaleAnswerIsDroppedAfterTheAddressChanged() async {
        let services = SlowServices()
        let server = controller(services: services)
        let look = Task { await server.check() }
        await services.waitUntilAsked()
        // The person gives another address while the first look is under way.
        server.setAddress("http://127.0.0.1:8090")
        services.release()
        await look.value
        #expect(server.state == .notChecked)
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)
        #expect(server.addressText == "http://127.0.0.1:8090")
    }

    @Test func theTimeoutsAreAlignedAndTheMessageNamesThem() async {
        #expect(ResearchServerController.requestTimeout == 8)
        let slow = TimedOutServices()
        let server = controller(services: slow)
        await server.check()
        #expect(server.state == .off)
        #expect(server.offReason == "no answer within 8 seconds")
    }

    @Test func aRunningServerWithoutModelsIsAProblem() async {
        let server = controller(services: FakeResearchServices(listedModels: []))
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("no model"))
    }

    @Test func changingTheAddressDropsWhatWasFound() async {
        let server = controller()
        await server.check()
        #expect(server.state == .ready)
        server.setAddress("http://127.0.0.1:8090")
        #expect(server.state == .notChecked)
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)
    }

    // MARK: llama.cpp and its key

    @Test func llamaCppIsAskedWithTheKeyAndStaysNonStreaming() async {
        let services = FakeResearchServices(
            listedModels: ["bonsai"], tuffStatus: false, requiredKey: "test-key",
            llamaContext: 16_384)
        let server = controller(services: services)
        server.select(.llamacpp)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.models.map(\.id) == ["bonsai"])
        #expect(server.connection?.kind == .llamacpp)
        #expect(server.connection?.streaming == false)
        #expect(server.authorization == "Bearer test-key")
        #expect(services.authorizations.contains {
            $0.path == "/props" && $0.value == "Bearer test-key"
        })
        #expect(services.authorizations.contains {
            $0.path == "/v1/models" && $0.value == "Bearer test-key"
        })
        #expect(server.connection?.contextTokens == 16_384)
        #expect(!server.needsPromptBudget)
    }

    @Test func aWrongKeyIsRefusedEvenThoughTheModelListIsPublic() async {
        let services = FakeResearchServices(
            tuffStatus: false, requiredKey: "another-key", llamaContext: 8192)
        let server = controller(services: services)
        server.select(.llamacpp)
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("refused the key"))
        #expect(message.contains("key file"))
        #expect(!message.contains("test-key"))
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)
    }

    @Test func aServerWithoutLlamaCppsPropsIsNotAcceptedAsLlamaCpp() async {
        // Answers /v1/models and everything else like an OpenAI-compatible
        // server, but has no /props: Ollama, LM Studio, a second TUFF.
        let services = FakeResearchServices(tuffStatus: false, llamaContext: nil)
        let server = controller(services: services)
        server.select(.llamacpp)
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("does not look like llama.cpp"))
        #expect(server.models.isEmpty)
        #expect(server.connection == nil)
        #expect(server.state != .ready)
    }

    @Test func aPropsAnswerWithoutTheExpectedShapeIsNotLlamaCpp() async {
        let props = FixedPropsServices(body: #"{"hello":"world"}"#)
        let server = controller(services: props)
        server.select(.llamacpp)
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("default_generation_settings"))
    }

    @Test func llamaCppWithoutAContextSizeAsksForAPromptBudget() async {
        let services = FakeResearchServices(tuffStatus: false, llamaContext: .some(nil))
        let server = controller(services: services)
        server.select(.llamacpp)
        #expect(server.needsPromptBudget)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.connection?.contextTokens == nil)
        #expect(server.needsPromptBudget)
        // TUFF never needs one: its model list gives the window.
        server.select(.tuff)
        #expect(!server.needsPromptBudget)
    }

    @Test func aTuffServerAtTheLlamaCppAddressIsNamed() async {
        let server = controller(services: FakeResearchServices())
        server.select(.llamacpp)
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("TUFF server answers"))
    }

    @Test func theStartCommandNamesTheKeyFileAndNeverHoldsTheKey() {
        let path = "/Users/me/Library/Application Support/SandSeek/State/llamacpp-api-key"
        let server = controller(keys: MemoryKeyStore(key: "abc123", filePath: path))
        #expect(server.startCommand == nil)
        server.select(.llamacpp)
        #expect(server.startCommand
            == "llama-server -m <model.gguf> --alias <name> --host 127.0.0.1 --port 8081 "
            + "-c 16384 -np 1 --jinja --api-key-file "
            + "'/Users/me/Library/Application Support/SandSeek/State/llamacpp-api-key'")
        #expect(server.startCommand?.contains("abc123") == false)
        #expect(server.startCommand?.contains("--api-key ") == false)
        server.setAddress("http://localhost:9191")
        #expect(server.startCommand?.contains("--port 9191") == true)
        // The command always binds loopback, whatever name the address used.
        #expect(server.startCommand?.contains("--host 127.0.0.1") == true)
        server.setAddress("http://[::1]:9191")
        #expect(server.startCommand?.contains("--host ::1") == true)
    }

    @Test func aPathWithAQuoteIsQuotedForTheShell() {
        #expect(ResearchServerController.shellQuoted("/a b/it's") == "'/a b/it'\\''s'")
        let server = controller(keys: MemoryKeyStore(key: "k"))
        server.select(.llamacpp)
        // No file: a placeholder, still not the key.
        #expect(server.startCommand?.hasSuffix("--api-key-file <key file>") == true)
    }

    @Test func hintsNameHowToStartEachType() {
        let server = controller()
        #expect(server.startHint.contains("Background API"))
        #expect(server.startHint.contains("tuff serve"))
        #expect(server.startHint.contains("8080"))
        server.select(.llamacpp)
        #expect(server.startHint.contains("command below"))
        #expect(ResearchServerController.memoryNote.contains("one model server"))
        #expect(ResearchServerController.memoryNote.contains("16 GB"))
        #expect(ResearchServerController.keyNote.contains("--api-key-file"))
        // No plan jargon in text people read.
        for text in [ResearchServerController.keyNote, ResearchServerController.memoryNote,
                     server.startHint] {
            #expect(!text.contains("2b"))
            #expect(!text.contains("Abschnitt"))
        }
    }

    @Test func theKeyIsMadeOnceAndKept() {
        let keys = MemoryKeyStore()
        let first = controller(keys: keys)
        #expect(first.apiKey.count == 64)
        #expect(first.apiKey.allSatisfy { $0.isHexDigit })
        #expect(keys.stored == first.apiKey)
        #expect(first.keyProblem == nil)
        let second = controller(keys: keys)
        #expect(second.apiKey == first.apiKey)
        // A different store gets a different key.
        #expect(controller(keys: MemoryKeyStore()).apiKey != first.apiKey)
    }

    @Test func aKeyThatCannotBeSavedIsStillUsedAndReported() {
        let server = controller(keys: MemoryKeyStore(failsToSave: true))
        #expect(server.apiKey.count == 64)
        #expect(server.keyProblem?.contains("could not be saved") == true)
    }

    @Test func theKeyFileIsPrivate() throws {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("State/llamacpp-api-key")
        let store = FileKeyStore(url: url)
        #expect(store.loadKey() == nil)
        try store.saveKey("secret-value")
        #expect(store.loadKey() == "secret-value")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(store.keyFilePath == url.path)
    }

    @Test func aFolderThatExistedWithOpenPermissionsIsClosed() throws {
        let folder = temporaryDirectory().appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let store = FileKeyStore(url: folder.appendingPathComponent("llamacpp-api-key"))
        try store.saveKey("secret-value")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // Saving again over an existing file keeps it private.
        try store.saveKey("another-value")
        let file = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("llamacpp-api-key").path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

/// Stands in for the check of the Mac's network addresses: counts the ports
/// it was asked about and answers from a script.
private final class ExposureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Int] = []
    private let reachable: [ResearchHostAddress]
    private let checked: [ResearchHostAddress]

    init(reachable: [ResearchHostAddress] = [],
         checked: [ResearchHostAddress] = [.ipv4(192, 168, 1, 5)]) {
        self.reachable = reachable
        self.checked = checked
    }

    var ports: [Int] { lock.withLock { asked } }

    func run(_ port: Int) async -> ResearchExposureReport {
        lock.withLock { asked.append(port) }
        return ResearchExposureReport(
            port: port, loopbackAnswered: true, checked: checked, reachable: reachable)
    }
}

@Suite @MainActor struct ResearchServerExposureTests {
    private func controller(services: any ResearchHTTPTransport = FakeResearchServices(),
                            probe: ExposureProbe?) -> ResearchServerController {
        var check: (@Sendable (Int) async -> ResearchExposureReport)?
        if let probe { check = { port in await probe.run(port) } }
        return ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "test-key"),
            transport: services, exposureCheck: check)
    }

    @Test func withoutACheckNothingIsLookedAt() async {
        let server = controller(probe: nil)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.exposure == .notChecked)
    }

    @Test func checkTriesTheServersPortOnceAndPollingDoesNot() async {
        let probe = ExposureProbe()
        let server = controller(probe: probe)
        await server.check()
        #expect(probe.ports == [8080])
        #expect(server.exposure == .notReachable(addresses: 1))

        // The periodic look and the reload button leave the network alone.
        await server.refresh()
        await server.refresh()
        await server.refreshModels()
        #expect(probe.ports == [8080])
        #expect(server.exposure == .notReachable(addresses: 1))

        // Check again, check again.
        await server.check()
        #expect(probe.ports == [8080, 8080])
    }

    @Test func theAddressesPortIsTheOneThatIsTried() async {
        let probe = ExposureProbe()
        let services = FakeResearchServices(
            tuffStatus: false, requiredKey: "test-key", llamaContext: 8192)
        let llama = controller(services: services, probe: probe)
        llama.select(.llamacpp)
        await llama.check()
        #expect(llama.state == .ready)
        #expect(probe.ports == [8081])
        llama.setAddress("http://127.0.0.1:9090")
        await llama.check()
        #expect(probe.ports == [8081, 9090])
    }

    @Test func anAnsweringAddressBecomesTheWarning() async {
        let probe = ExposureProbe(reachable: [.ipv4(192, 168, 1, 5)])
        let server = controller(probe: probe)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.exposure == .reachable(
            "Reachable from the network at 192.168.1.5:8080; start the server with --host 127.0.0.1"))
    }

    @Test func aMacWithoutNetworkAddressesIsCountedAsNotReachable() async {
        let server = controller(probe: ExposureProbe(checked: []))
        await server.check()
        #expect(server.exposure == .notReachable(addresses: 0))
    }

    @Test func aServerThatDoesNotAnswerIsNotChecked() async {
        let probe = ExposureProbe(reachable: [.ipv4(192, 168, 1, 5)])
        let server = controller(services: NothingListens(), probe: probe)
        await server.check()
        #expect(server.state == .off)
        #expect(server.exposure == .notChecked)
        #expect(probe.ports.isEmpty)
    }

    @Test func aServerThatAnswersWithAProblemIsStillChecked() async {
        // A server that is up but is not the chosen kind can still be reachable.
        let probe = ExposureProbe(reachable: [.ipv4(10, 0, 0, 9)])
        let server = controller(services: FakeResearchServices(tuffStatus: false), probe: probe)
        await server.check()
        guard case .problem = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(probe.ports == [8080])
        #expect(server.exposure == .reachable(
            "Reachable from the network at 10.0.0.9:8080; start the server with --host 127.0.0.1"))
    }

    @Test func changingTheAddressOrTypeForgetsTheResult() async {
        let probe = ExposureProbe(reachable: [.ipv4(192, 168, 1, 5)])
        let server = controller(probe: probe)
        await server.check()
        if case .reachable = server.exposure {} else {
            Issue.record("expected a warning, got \(server.exposure)")
        }
        server.setAddress("http://127.0.0.1:8090")
        #expect(server.exposure == .notChecked)
        await server.check()
        server.select(.llamacpp)
        #expect(server.exposure == .notChecked)
    }

    @Test func aServerThatGoesAwayForgetsTheWarning() async {
        let services = FakeResearchServices()
        let probe = ExposureProbe(reachable: [.ipv4(192, 168, 1, 5)])
        let server = controller(services: services, probe: probe)
        await server.check()
        if case .reachable = server.exposure {} else {
            Issue.record("expected a warning, got \(server.exposure)")
        }
        services.setDown(true)
        await server.refresh()
        #expect(server.state == .off)
        #expect(server.exposure == .notChecked)
    }

    @Test func aNewAddressDuringTheCheckDropsItsAnswer() async {
        let gate = SlowExposure()
        let services = FakeResearchServices()
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
            transport: services,
            exposureCheck: { port in await gate.run(port) })
        let check = Task { await server.check() }
        await gate.waitUntilAsked()
        #expect(server.exposure == .checking)
        server.setAddress("http://127.0.0.1:8090")
        gate.release()
        await check.value
        #expect(server.exposure == .notChecked)
    }

    @Test func theRealCheckIsOnlyGivenToTheWorkspaceNotToTheDefaultController() {
        // The default controller has no check, so tests and previews never
        // open connections to this machine's addresses.
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"))
        #expect(server.exposure == .notChecked)
    }
}

/// An exposure check that waits until `release()`.
private final class SlowExposure: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    private var released = false

    func waitUntilAsked() async {
        while !lock.withLock({ asked }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func release() { lock.withLock { released = true } }

    func run(_ port: Int) async -> ResearchExposureReport {
        lock.withLock { asked = true }
        while !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(5)) }
        return ResearchExposureReport(
            port: port, loopbackAnswered: true, checked: [.ipv4(192, 168, 1, 5)],
            reachable: [.ipv4(192, 168, 1, 5)])
    }
}
