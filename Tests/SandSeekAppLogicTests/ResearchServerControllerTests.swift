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
        // Same address, nothing there any more.
        let gone = controller(services: NothingListens())
        await gone.refresh()
        #expect(gone.state == .off)
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
            listedModels: ["bonsai"], tuffStatus: false, requiredKey: "test-key")
        let server = controller(services: services)
        server.select(.llamacpp)
        await server.check()
        #expect(server.state == .ready)
        #expect(server.models.map(\.id) == ["bonsai"])
        #expect(server.connection?.kind == .llamacpp)
        #expect(server.connection?.streaming == false)
        #expect(server.authorization == "Bearer test-key")
        #expect(services.authorizations.contains {
            $0.path == "/v1/models" && $0.value == "Bearer test-key"
        })
    }

    @Test func aRefusedKeyIsExplained() async {
        let services = FakeResearchServices(tuffStatus: false, requiredKey: "another-key")
        let server = controller(services: services)
        server.select(.llamacpp)
        await server.check()
        guard case .problem(let message) = server.state else {
            Issue.record("expected a problem, got \(server.state)")
            return
        }
        #expect(message.contains("refused the key"))
        #expect(message.contains("--api-key"))
        #expect(!message.contains("test-key"))
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

    @Test func theStartCommandHasTheKeyAndFollowsThePort() {
        let server = controller(keys: MemoryKeyStore(key: "abc123"))
        #expect(server.startCommand == nil)
        server.select(.llamacpp)
        #expect(server.startCommand
            == "llama-server -m <model.gguf> --alias <name> --host 127.0.0.1 --port 8081 "
            + "-c 16384 -np 1 --jinja --api-key abc123")
        server.setAddress("http://localhost:9191")
        #expect(server.startCommand?.contains("--port 9191") == true)
        // The command always binds loopback, whatever name the address used.
        #expect(server.startCommand?.contains("--host 127.0.0.1") == true)
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
        #expect(ResearchServerController.keyNote.contains("2b"))
        #expect(ResearchServerController.keyNote.contains("--api-key"))
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
    }
}
