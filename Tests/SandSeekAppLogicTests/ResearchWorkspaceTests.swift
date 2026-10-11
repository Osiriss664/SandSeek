import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// Answers the sandbox and the model from a fake, but holds the first model
/// request until the run is stopped, so a run stays in progress.
private final class BusyRunServices: ResearchHTTPTransport, @unchecked Sendable {
    let inner: FakeResearchServices

    init(_ inner: FakeResearchServices) { self.inner = inner }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        if url.path == "/v1/chat/completions" {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw URLError(.cancelled)
        }
        return try await inner.send(method: method, url: url, body: body)
    }
}

@Suite @MainActor struct ResearchWorkspaceTests {
    private struct Setup {
        let workspace: ResearchWorkspace
        let server: ResearchServerController
        let serverServices: FakeResearchServices
        let runServices: FakeResearchServices
        let run: ResearchRunController
        let launch: ResearchServerLaunchController
    }

    private static let settings = ResearchRunSettings(
        model: "m", maxSteps: 2, autoOpenPages: false, nudges: false, reviseUnreadCitations: false)

    private func setup(llamaCpp: Bool = false,
                       busyRun: Bool = false,
                       launch: ResearchServerLaunchController? = nil) async throws -> Setup {
        let serverServices = llamaCpp
            ? FakeResearchServices(listedModels: ["m"], tuffStatus: false,
                                   requiredKey: "test-key", llamaContext: .some(nil))
            : FakeResearchServices(listedModels: ["m"])
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "test-key"),
            transport: serverServices,
            // The fakes answer with whole replies, not streams.
            tuffStreaming: false)
        if llamaCpp { server.select(.llamacpp) }
        await server.check()
        let reports = ResearchReportStore(directory: temporaryDirectory())
        let runServices = FakeResearchServices(
            modelReplies: Array(repeating: FakeResearchServices.answer("An answer."), count: 4))
        let run = ResearchRunController(
            store: reports, transport: busyRun ? BusyRunServices(runServices) : runServices)
        let sandbox = ResearchSandboxController(
            runner: FakeProcessRunner(), transport: FakeResearchServices(),
            defaults: MemorySettings(), environment: [:], resources: try testResources(),
            stateDirectory: temporaryDirectory())
        await sandbox.start()
        let launch = launch ?? testLaunchController()
        let workspace = ResearchWorkspace(
            sandbox: sandbox, server: server, reports: reports, run: run,
            presets: ResearchPresetStore(defaults: MemorySettings()), launch: launch)
        return Setup(workspace: workspace, server: server, serverServices: serverServices,
                     runServices: runServices, run: run, launch: launch)
    }

    @Test func refreshLeavesTheModelServerAloneWhileItIsStarting() async throws {
        // A server that never answers keeps the start waiting.
        let settings = MemorySettings()
        settings.save("/opt/TUFF/TUFFServer", forKey: "ResearchServerProgram-tuff")
        let silent = FakeResearchServices()
        silent.setDown(true)
        let launcher = FakeServerLauncher()
        let launch = testLaunchController(
            settings: settings, launcher: launcher, transport: silent,
            timing: .init(poll: .milliseconds(5), tuffReady: .seconds(30),
                          stopGrace: .milliseconds(100), killGrace: .milliseconds(100)))
        let setup = try await setup(launch: launch)
        let starting = Task { await launch.start(using: setup.server) }
        await waitUntil { launch.state == .starting && launch.owned != nil }
        #expect(launch.state == .starting)

        setup.serverServices.clearPaths()
        await setup.workspace.refresh()
        #expect(setup.serverServices.paths.isEmpty)
        #expect(setup.server.state == .ready)

        await launch.stop()
        await starting.value
        #expect(launcher.servers.first?.signals == ["TERM"])
        await setup.workspace.refresh()
        #expect(!setup.serverServices.paths.isEmpty)
    }

    @Test func quittingStopsTheModelServerBeforeTheSandboxAndOnlyAnOwnedOne() async throws {
        // The sandbox's stop script notes whether the server had been told to
        // end before the script ran.
        let marks = temporaryDirectory("SandSeekQuit")
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        let bundle = try fakeSandboxBundle()
        let script = """
        #!/bin/bash
        if [ "$1" = stop ]; then
          if [ -e '\(marks.path)/server-term' ]; then echo ordered > '\(marks.path)/result'
          else echo wrong > '\(marks.path)/result'; fi
        fi
        """
        try Data(script.utf8).write(
            to: bundle.appendingPathComponent("Scripts/research_sandbox.sh"))

        let services = FakeResearchServices(listedModels: ["m"])
        services.setDown(true)
        let launcher = FakeServerLauncher()
        launcher.onSignal = { signal in
            if signal == "TERM" {
                try? Data().write(to: marks.appendingPathComponent("server-term"))
            }
        }
        let settings = MemorySettings()
        settings.save("/opt/TUFF/TUFFServer", forKey: "ResearchServerProgram-tuff")
        let launch = testLaunchController(
            settings: settings,
            launcher: HookedLauncher(inner: launcher, after: { services.setDown(false) }),
            transport: services,
            timing: .init(poll: .milliseconds(5), stopGrace: .milliseconds(200),
                          killGrace: .milliseconds(200)))
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "test-key"),
            transport: services, tuffStreaming: false)
        let reports = ResearchReportStore(directory: temporaryDirectory())
        let sandbox = ResearchSandboxController(
            runner: FakeProcessRunner(), transport: FakeResearchServices(),
            defaults: MemorySettings(), environment: [:],
            resources: try testResources(bundle: bundle), stateDirectory: temporaryDirectory())
        await sandbox.start()
        let workspace = ResearchWorkspace(
            sandbox: sandbox, server: server, reports: reports,
            run: ResearchRunController(store: reports, transport: FakeResearchServices()),
            presets: ResearchPresetStore(defaults: MemorySettings()), launch: launch)

        // No server of ours: nothing is signalled.
        workspace.shutdown()
        #expect(launcher.servers.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: marks.appendingPathComponent("server-term").path))
        try? FileManager.default.removeItem(at: marks.appendingPathComponent("result"))

        await launch.start(using: server)
        #expect(launch.state == .running)
        workspace.shutdown()
        let result = try? String(
            contentsOf: marks.appendingPathComponent("result"), encoding: .utf8)
        #expect(result?.trimmingCharacters(in: .whitespacesAndNewlines) == "ordered")
        #expect(launcher.servers.first?.signals == ["TERM"])
        #expect(launch.owned == nil)
    }

    @Test func refreshLeavesTheModelServerAloneWhileAQuestionRuns() async throws {
        let setup = try await setup(busyRun: true)
        #expect(setup.workspace.servicesReady)
        await setup.workspace.ask("Question", settings: Self.settings)
        #expect(setup.run.isRunning)

        setup.serverServices.clearPaths()
        await setup.workspace.refresh()
        #expect(setup.serverServices.paths.isEmpty)

        setup.run.stop()
        await waitUntil { !setup.run.isRunning }
        await setup.workspace.refresh()
        // Idle again: the cheap status route is asked.
        #expect(setup.serverServices.paths == ["/tuff/v1/status"])
    }

    @Test func aQuestionCarriesTheKeyOfLlamaCppAndNoneForTuff() async throws {
        let llama = try await setup(llamaCpp: true)
        #expect(llama.workspace.servicesReady)
        await llama.workspace.ask("Question", settings: Self.settings)
        await waitUntil { !llama.run.isRunning }
        let chat = llama.runServices.authorizations.filter { $0.path == "/v1/chat/completions" }
        #expect(!chat.isEmpty)
        #expect(chat.allSatisfy { $0.value == "Bearer test-key" })
        #expect(llama.run.report?.serverKind == "llamacpp")

        let tuff = try await setup()
        await tuff.workspace.ask("Question", settings: Self.settings)
        await waitUntil { !tuff.run.isRunning }
        let tuffChat = tuff.runServices.authorizations.filter { $0.path == "/v1/chat/completions" }
        #expect(!tuffChat.isEmpty)
        #expect(tuffChat.allSatisfy { $0.value == nil })
        #expect(tuff.run.report?.serverKind == "tuff")
    }

    @Test func theKeyNeverReachesTheSandboxOrTheReport() async throws {
        let llama = try await setup(llamaCpp: true)
        await llama.workspace.ask("Question", settings: Self.settings)
        await waitUntil { !llama.run.isRunning }
        let sandboxCalls = llama.runServices.authorizations.filter {
            $0.path.hasPrefix("/v1/search") || $0.path.hasPrefix("/v1/fetch") || $0.path == "/health"
        }
        #expect(sandboxCalls.allSatisfy { $0.value == nil })
        let report = try #require(llama.run.report)
        #expect(!report.markdown.contains("test-key"))
        #expect(!report.answer.contains("test-key"))
    }

    @Test func aLlamaCppWithoutAContextSizeGetsTheBudgetFromSettings() {
        let unknown = ResearchServerConnection(kind: .llamacpp, version: nil, streaming: false)
        let known = ResearchServerConnection(
            kind: .llamacpp, version: nil, streaming: false, contextTokens: 8192)
        let tuff = ResearchServerConnection(kind: .tuff, version: nil, streaming: true)
        let plain = ResearchRunSettings(model: "m")

        #expect(ResearchWorkspace.applyingPromptBudget(
            to: plain, connection: unknown, budget: 32_000).contextCharacters == 32_000)
        #expect(ResearchWorkspace.applyingPromptBudget(
            to: plain, connection: unknown, budget: nil).contextCharacters == nil)
        // The server gave its context size, or it is not llama.cpp: no budget is forced.
        #expect(ResearchWorkspace.applyingPromptBudget(
            to: plain, connection: known, budget: 32_000).contextCharacters == nil)
        #expect(ResearchWorkspace.applyingPromptBudget(
            to: plain, connection: tuff, budget: 32_000).contextCharacters == nil)
        // A budget already in the settings is kept.
        var fixed = plain
        fixed.contextCharacters = 12_000
        #expect(ResearchWorkspace.applyingPromptBudget(
            to: fixed, connection: unknown, budget: 32_000).contextCharacters == 12_000)
    }

    @Test func theContextWindowFromTheServerReachesTheRunOptions() {
        let connection = ResearchServerConnection(
            kind: .llamacpp, version: nil, streaming: false, contextTokens: 8192)
        let options = ResearchRunController.runOptions(
            settings: ResearchRunSettings(model: "m"), connection: connection)
        #expect(options.knownContextTokens == 8192)
        #expect(options.contextBudgetCharacters == nil)

        var fixed = ResearchRunSettings(model: "m")
        fixed.contextCharacters = 20_000
        let both = ResearchRunController.runOptions(settings: fixed, connection: connection)
        #expect(both.contextBudgetCharacters == 20_000)

        let none = ResearchRunController.runOptions(
            settings: ResearchRunSettings(model: "m"),
            connection: ResearchServerConnection(kind: .tuff, version: nil, streaming: false))
        #expect(none.knownContextTokens == nil)
    }

    @Test func aQuickRunSendsNoThinkingFieldAndTheCommandsTokenLimit() async throws {
        // Quick leaves thinking to the server: no enable_thinking is sent.
        let settings = ResearchPreset.quick.runSettings(model: "m")
        let services = FakeResearchServices(modelReplies: [FakeResearchServices.answer("Done.")])
        let run = ResearchRunController(
            store: ResearchReportStore(directory: temporaryDirectory()), transport: services)
        var quick = settings
        quick.nudges = false
        quick.autoOpenPages = false
        quick.reviseUnreadCitations = false
        run.start(question: "Q", settings: quick,
                  serverURL: URL(string: "http://127.0.0.1:8081")!,
                  sandboxURL: URL(string: "http://127.0.0.1:9100")!)
        await waitUntil { !run.isRunning }
        #expect(services.chatBodies.count >= 1)
        for body in services.chatBodies {
            #expect(body["enable_thinking"] == nil)
            #expect(body["max_tokens"]?.intValue == 2_048)
        }
    }
}
