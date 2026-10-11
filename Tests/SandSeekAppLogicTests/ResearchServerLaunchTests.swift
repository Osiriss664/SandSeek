import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// A port whose answer never comes.
private final class TimedOutPort: ResearchHTTPTransport, @unchecked Sendable {
    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        throw URLError(.timedOut)
    }
}

@Suite @MainActor struct ResearchServerLaunchTests {
    private static let fast = ResearchServerLaunchController.Timing(
        poll: .milliseconds(5), tuffReady: .seconds(5), llamaReady: .seconds(5),
        stopGrace: .milliseconds(150), killGrace: .milliseconds(150))

    private struct Rig {
        let launch: ResearchServerLaunchController
        let server: ResearchServerController
        let launcher: FakeServerLauncher
        let services: FakeResearchServices
        let stateDirectory: URL
        let folder: URL
        let logURL: URL
        var keyFile: String { folder.appendingPathComponent("key").path }
        var model: String { folder.appendingPathComponent("Test-Model.gguf").path }
        var markerExists: Bool { ResearchServerMarker.load(from: stateDirectory) != nil }
    }

    /// A card with TUFF (or llama.cpp) chosen, the program, model and key file
    /// in place, and a fake launcher. The port is free until the launcher
    /// starts a server, unless `answering`; the server then answers unless
    /// `becomesReady` is false. `script` runs a real program instead of the
    /// fake launcher.
    private func makeRig(llama: Bool = false, modelsFolder: Bool = false,
                     keyMode: Int = 0o600, keyText: String? = nil,
                     keyFile: Bool = true, keySaves: Bool = true,
                     exposure: ResearchExposureReport? = nil,
                     answering: Bool = false, becomesReady: Bool = true,
                     portTransport: (any ResearchHTTPTransport)? = nil,
                     timing: ResearchServerLaunchController.Timing = ResearchServerLaunchTests.fast,
                     launcher: FakeServerLauncher = FakeServerLauncher(),
                     script: String? = nil) throws -> Rig {
        let folder = temporaryDirectory("SandSeekLaunch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keyPath = folder.appendingPathComponent("key").path
        try Data((keyText ?? "test-key").utf8).write(to: URL(fileURLWithPath: keyPath))
        try FileManager.default.setAttributes([.posixPermissions: keyMode], ofItemAtPath: keyPath)
        try Data("gguf".utf8).write(to: folder.appendingPathComponent("Test-Model.gguf"))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("models"), withIntermediateDirectories: true)

        var program = llama ? "/opt/bin/llama-server" : "/opt/TUFF/TUFFServer"
        if let script {
            program = folder.appendingPathComponent("TUFFServer").path
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: URL(fileURLWithPath: program))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: program)
        }
        let settings = MemorySettings()
        settings.save(program, forKey: llama ? "ResearchServerProgram-llamacpp" : "ResearchServerProgram-tuff")
        if llama {
            settings.save(folder.appendingPathComponent("Test-Model.gguf").path,
                          forKey: "ResearchServerModel-llamacpp")
        } else if modelsFolder {
            settings.save(folder.appendingPathComponent("models").path,
                          forKey: "ResearchServerModels-tuff")
        }

        let services = llama
            ? FakeResearchServices(listedModels: ["m"], tuffStatus: false,
                                   requiredKey: "test-key", llamaContext: .some(nil))
            : FakeResearchServices(listedModels: ["m"])
        if !answering { services.setDown(true) }
        var check: (@Sendable (Int) async -> ResearchExposureReport)?
        if let exposure { check = { _ in exposure } }
        let keys = MemoryKeyStore(
            key: keySaves ? "test-key" : nil, failsToSave: !keySaves,
            filePath: keyFile ? keyPath : nil)
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: keys, transport: services,
            tuffStreaming: false, exposureCheck: check)
        if llama { server.select(.llamacpp) }

        let inner: any ResearchServerLaunching = script == nil ? launcher : FoundationServerLauncher()
        let hooked = HookedLauncher(inner: inner, after: {
            if becomesReady { services.setDown(false) }
        })
        let state = folder.appendingPathComponent("State")
        let log = folder.appendingPathComponent("Logs/model-server.log")
        let launch = testLaunchController(
            settings: settings, launcher: hooked, transport: portTransport ?? services,
            stateDirectory: state, logURL: log, timing: timing)
        return Rig(launch: launch, server: server, launcher: launcher, services: services,
                   stateDirectory: state, folder: folder, logURL: log)
    }

    private func failure(_ rig: Rig) -> String {
        if case .failed(let message) = rig.launch.state { return message }
        return "state is \(rig.launch.state)"
    }

    // MARK: - Starting

    @Test func tuffStartsWithThePortAndWaitsUntilItAnswers() async throws {
        let rig = try makeRig(modelsFolder: true)
        #expect(rig.launch.startBlocker(for: rig.server) == nil)
        await rig.launch.start(using: rig.server)
        #expect(rig.launch.state == .running)
        #expect(rig.launcher.plans.count == 1)
        let plan = rig.launcher.plans[0]
        #expect(plan.executable == "/opt/TUFF/TUFFServer")
        #expect(plan.arguments == ["--port", "8080", "--models-root", rig.folder.path + "/models"])
        #expect(Set(plan.environment.keys) == ["PATH", "HOME", "TMPDIR"])
        // Then the normal Check ran.
        #expect(rig.server.state == .ready)
        #expect(rig.launch.owned?.pid == 41_000)
        #expect(rig.markerExists)
    }

    @Test func llamaCppStartsWithTheSameArgumentsAsTheCopiedCommand() async throws {
        let rig = try makeRig(llama: true)
        await rig.launch.start(using: rig.server)
        #expect(rig.launch.state == .running)
        let plan = rig.launcher.plans[0]
        #expect(plan.arguments == [
            "-m", rig.model, "--alias", "Test-Model", "--host", "127.0.0.1", "--port", "8081",
            "-c", "16384", "-np", "1", "--jinja", "--api-key-file", rig.keyFile,
        ])
        // The copied command is the same list, with placeholders for the model.
        let tokens = (rig.server.startCommand ?? "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "<model.gguf>", with: rig.model)
            .replacingOccurrences(of: "<name>", with: "Test-Model")
            .split(separator: " ").map(String.init)
        #expect(tokens == ["llama-server"] + plan.arguments)
        #expect(rig.server.state == .ready)
    }

    @Test func startIsRefusedWhenSomethingAlreadyAnswersOnThePort() async throws {
        let rig = try makeRig(answering: true)
        await rig.launch.start(using: rig.server)
        #expect(failure(rig).contains("already answers on 127.0.0.1:8080"))
        #expect(failure(rig).contains("did not start it"))
        #expect(rig.launcher.plans.isEmpty)
    }

    @Test func startIsRefusedWhenThePortGivesNoClearAnswer() async throws {
        let rig = try makeRig(portTransport: TimedOutPort())
        await rig.launch.start(using: rig.server)
        #expect(failure(rig).contains("may already be in use"))
        #expect(rig.launcher.plans.isEmpty)
    }

    @Test func llamaCppNeverStartsWithoutAWorkingKeyFile() async throws {
        func refused(_ expected: String, _ rig: Rig) async {
            await rig.launch.start(using: rig.server)
            #expect(failure(rig).contains(expected), "\(expected): \(failure(rig))")
            #expect(rig.launcher.plans.isEmpty)
            #expect(rig.launch.owned == nil)
        }
        await refused("mode 0600", try makeRig(llama: true, keyMode: 0o644))
        await refused("does not hold", try makeRig(llama: true, keyText: "another-key"))
        await refused("no key file", try makeRig(llama: true, keyFile: false))
        await refused("could not be saved", try makeRig(llama: true, keySaves: false))
    }

    @Test func startNeedsALoopbackHostAFreePortRangeAndTheChoices() async throws {
        let rig = try makeRig()
        rig.server.setAddress("http://[::1]:8080")
        #expect(rig.launch.startBlocker(for: rig.server)?.contains("127.0.0.1") == true)
        rig.server.setAddress("http://localhost:8080")
        #expect(rig.launch.startBlocker(for: rig.server) == nil)
        rig.server.setAddress("http://127.0.0.1:80")
        #expect(rig.launch.startBlocker(for: rig.server)?.contains("1024") == true)
        rig.server.select(.llamacpp)
        #expect(rig.launch.startBlocker(for: rig.server) == "Choose the program first.")
    }

    @Test func aPickIsMappedCheckedAndRemembered() async throws {
        let folder = temporaryDirectory("SandSeekPick")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tuff = folder.appendingPathComponent("tuff").path
        let server = folder.appendingPathComponent("TUFFServer").path
        for path in [tuff, server] { try Data("x".utf8).write(to: URL(fileURLWithPath: path)) }
        let settings = MemorySettings()
        let launch = testLaunchController(settings: settings)
        // `tuff` becomes the TUFFServer beside it, so that Stop ends the real server.
        launch.chooseProgram(tuff, for: .tuff)
        #expect(launch.programs[.tuff] == server)
        #expect(launch.choiceProblem == nil)
        #expect(settings.savedString(forKey: "ResearchServerProgram-tuff") == server)
        launch.chooseProgram("/bin/sh", for: .tuff)
        #expect(launch.choiceProblem?.contains("TUFFServer") == true)
        #expect(launch.programs[.tuff] == server)
        launch.chooseProgram("/bin/sh", for: .llamacpp)
        #expect(launch.programs[.llamacpp] == nil)
        // A model must be an existing .gguf file, the models folder a folder.
        launch.chooseModel(folder.path, for: .llamacpp)
        #expect(launch.models[.llamacpp] == nil)
        launch.chooseModel(folder.path, for: .tuff)
        #expect(launch.models[.tuff] == folder.path)
        launch.chooseModel("", for: .tuff)
        #expect(launch.models[.tuff] == nil)
    }

    // MARK: - While it starts

    @Test func aServerThatEndsDuringTheWaitFailsWithTheEndOfItsLog() async throws {
        let launcher = FakeServerLauncher()
        launcher.logText = "starting\nbind: Address already in use\n"
        launcher.endsAtOnce = ResearchServerExit(code: 1, bySignal: false)
        // The port answers once the program is "running": the success must
        // not count, because the child is gone.
        let rig = try makeRig(launcher: launcher)
        await rig.launch.start(using: rig.server)
        #expect(failure(rig).contains("ended (exit 1)"))
        #expect(rig.launch.logTail.contains("Address already in use"))
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func aServerKilledAtOnceMentionsGatekeeperAndMemory() async throws {
        let launcher = FakeServerLauncher()
        launcher.endsAtOnce = ResearchServerExit(code: 9, bySignal: true)
        let rig = try makeRig(launcher: launcher)
        await rig.launch.start(using: rig.server)
        #expect(failure(rig).contains("signal 9"))
        #expect(failure(rig).contains("Gatekeeper"))
        #expect(ResearchServerLaunchController.endedMessage(
            ResearchServerExit(code: 9, bySignal: true), secondsSinceStart: 600)
            .contains("Gatekeeper") == false)
    }

    @Test func aServerThatNeverAnswersIsStoppedAfterTheTimeout() async throws {
        let rig = try makeRig(
            becomesReady: false,
            timing: .init(poll: .milliseconds(5), tuffReady: .milliseconds(300),
                          stopGrace: .milliseconds(150), killGrace: .milliseconds(150)))
        await rig.launch.start(using: rig.server)
        #expect(failure(rig).contains("did not answer within"))
        #expect(failure(rig).contains("stopped it"))
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func stopWorksWhileTheServerIsStillStarting() async throws {
        let rig = try makeRig(becomesReady: false)
        let starting = Task { await rig.launch.start(using: rig.server) }
        await waitUntil { rig.launch.state == .starting && rig.launch.owned != nil }
        #expect(rig.launch.state == .starting)
        #expect(rig.markerExists)

        await rig.launch.stop(using: rig.server)
        await starting.value
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.state == .idle)
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    // MARK: - Running and stopping

    @Test func stopStopsTheOwnedServerEvenAfterTheTypeWasChanged() async throws {
        let rig = try makeRig()
        await rig.launch.start(using: rig.server)
        rig.server.select(.llamacpp)
        #expect(rig.launch.owned?.type == .tuff)
        #expect(rig.launch.startBlocker(for: rig.server)?
            .contains("Stop the TUFF server SandSeek started first") == true)

        await rig.launch.stop(using: rig.server)
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.state == .idle)
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func aSecondStartIsRefusedWhileAnOwnedServerRuns() async throws {
        let rig = try makeRig()
        await rig.launch.start(using: rig.server)
        await rig.launch.start(using: rig.server)
        #expect(rig.launcher.plans.count == 1)
        #expect(rig.launch.state == .running)
    }

    @Test func aServerThatIgnoresTermIsKilledAfterTheGracePeriod() async throws {
        let launcher = FakeServerLauncher()
        launcher.ignoresTerm = true
        let rig = try makeRig(launcher: launcher)
        await rig.launch.start(using: rig.server)
        await rig.launch.stop(using: rig.server)
        #expect(rig.launcher.servers[0].signals == ["TERM", "KILL"])
        #expect(rig.launch.state == .idle)
    }

    @Test func aServerThatEndsByItselfWhileRunningIsReported() async throws {
        let rig = try makeRig()
        await rig.launch.start(using: rig.server)
        rig.launcher.servers[0].end(ResearchServerExit(code: 9, bySignal: true))
        await waitUntil { rig.launch.owned == nil }
        #expect(failure(rig).contains("ended (signal 9)"))
        #expect(!rig.markerExists)
    }

    @Test func aServerReachableFromTheNetworkIsStopped() async throws {
        let address = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let report = ResearchExposureReport(
            port: 8080, loopbackAnswered: true, checked: [address], reachable: [address])
        let rig = try makeRig(exposure: report)
        await rig.launch.start(using: rig.server)
        #expect(failure(rig).contains("Another program may be listening"))
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func aNetworkCheckThatCannotTellKeepsTheServerRunning() async throws {
        let address = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let report = ResearchExposureReport(
            port: 8080, loopbackAnswered: true, checked: [address], reachable: [],
            unknown: [address])
        let rig = try makeRig(exposure: report)
        await rig.launch.start(using: rig.server)
        #expect(rig.launch.state == .running)
        #expect(rig.launcher.servers[0].signals.isEmpty)
        if case .unclear = rig.server.exposure {} else {
            Issue.record("expected an unclear network check, got \(rig.server.exposure)")
        }
    }

    // MARK: - Quitting

    @Test func quittingStopsOnlyTheServerSandSeekStarted() async throws {
        let rig = try makeRig()
        // Nothing started: nothing is signalled and nothing breaks.
        rig.launch.beginStopWhenQuitting()
        rig.launch.finishStopWhenQuitting()
        #expect(rig.launcher.servers.isEmpty)

        await rig.launch.start(using: rig.server)
        rig.launch.beginStopWhenQuitting()
        // The server is told first and ends while the sandbox would be stopped.
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        rig.launch.finishStopWhenQuitting()
        #expect(rig.launch.owned == nil)
        #expect(!rig.markerExists)
    }

    @Test func quittingKillsAServerThatIgnoresTerm() async throws {
        let launcher = FakeServerLauncher()
        launcher.ignoresTerm = true
        let rig = try makeRig(launcher: launcher)
        await rig.launch.start(using: rig.server)
        rig.launch.beginStopWhenQuitting()
        rig.launch.finishStopWhenQuitting()
        #expect(rig.launcher.servers[0].signals == ["TERM", "KILL"])
        #expect(rig.launch.owned == nil)
    }

    @Test func quittingWhileTheServerStartsStopsIt() async throws {
        let rig = try makeRig(becomesReady: false)
        let starting = Task { await rig.launch.start(using: rig.server) }
        await waitUntil { rig.launch.owned != nil }
        rig.launch.beginStopWhenQuitting()
        rig.launch.finishStopWhenQuitting()
        await starting.value
        #expect(rig.launcher.servers[0].signals == ["TERM"])
        #expect(rig.launch.owned == nil)
    }

    // MARK: - After a crash

    private let identity = ResearchProcessIdentity(
        startSeconds: 1_000, startMicroseconds: 7, path: "/opt/TUFF/TUFFServer")

    private func leftoverController(
        marker: ResearchServerMarker?, running: ResearchProcessIdentity?
    ) throws -> (ResearchServerLaunchController, URL) {
        let state = temporaryDirectory("SandSeekState")
        try marker?.write(to: state)
        let launch = testLaunchController(stateDirectory: state, identityOf: { _ in running })
        return (launch, state)
    }

    @Test func aLeftoverServerThatMatchesIsTakenOverNotStopped() throws {
        let marker = ResearchServerMarker(type: "tuff", port: 8080, pid: 41_000, identity: identity)
        let (launch, state) = try leftoverController(marker: marker, running: identity)
        #expect(launch.owned == .init(
            type: .tuff, port: 8080, pid: 41_000, path: "/opt/TUFF/TUFFServer", adopted: true))
        #expect(launch.state == .running)
        #expect(ResearchServerMarker.load(from: state) == marker)
        // Start is off while it runs.
        #expect(launch.startBlocker(for: ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
            transport: FakeResearchServices()))?.contains("Stop the TUFF server") == true)
    }

    @Test func aMarkerThatDoesNotMatchIsDeletedAndNothingIsSignalled() throws {
        let marker = ResearchServerMarker(type: "tuff", port: 8080, pid: 41_000, identity: identity)
        // The process id now belongs to something else, or to nothing.
        let other = ResearchProcessIdentity(
            startSeconds: 2_000, startMicroseconds: 7, path: "/usr/bin/vim")
        for running in [other, nil] {
            let (launch, state) = try leftoverController(marker: marker, running: running)
            #expect(launch.owned == nil)
            #expect(launch.state == .idle)
            #expect(ResearchServerMarker.load(from: state) == nil)
        }
        // The same program at a different start time is not ours either.
        let reused = ResearchProcessIdentity(
            startSeconds: 1_000, startMicroseconds: 8, path: "/opt/TUFF/TUFFServer")
        let (launch, state) = try leftoverController(marker: marker, running: reused)
        #expect(launch.owned == nil)
        #expect(ResearchServerMarker.load(from: state) == nil)
    }

    // MARK: - Real processes

    private func gone(_ pid: Int32) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while kill(pid, 0) == 0 && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return kill(pid, 0) != 0
    }

    @Test func aRealServerIsStoppedWithSigtermAndItsLogIsPrivate() async throws {
        let rig = try makeRig(script: "exec sleep 60")
        await rig.launch.start(using: rig.server)
        #expect(rig.launch.state == .running)
        let pid = try #require(rig.launch.owned?.pid)
        let attributes = try FileManager.default.attributesOfItem(atPath: rig.logURL.path)
        #expect((attributes[.posixPermissions] as? Int ?? 0) & 0o777 == 0o600)

        await rig.launch.stop(using: rig.server)
        #expect(rig.launch.state == .idle)
        #expect(await gone(pid))
    }

    @Test func aRealServerThatIgnoresSigtermIsKilled() async throws {
        let rig = try makeRig(script: "trap '' TERM; exec sleep 60")
        await rig.launch.start(using: rig.server)
        let pid = try #require(rig.launch.owned?.pid)
        await rig.launch.stop(using: rig.server)
        #expect(rig.launch.state == .idle)
        #expect(await gone(pid))
    }

    @Test func quittingEndsARealServerWithoutTheMainActorRunning() async throws {
        let rig = try makeRig(script: "trap '' TERM; exec sleep 60")
        await rig.launch.start(using: rig.server)
        let pid = try #require(rig.launch.owned?.pid)
        // Synchronous, like applicationWillTerminate: the exit flag is set from
        // Foundation's own thread, so this returns although the main actor is busy.
        rig.launch.beginStopWhenQuitting()
        rig.launch.finishStopWhenQuitting()
        #expect(rig.launch.owned == nil)
        #expect(await gone(pid))
    }

    @Test func aRealServerGetsOnlyThreeEnvironmentVariables() async throws {
        setenv("LLAMA_ARG_API_KEY", "leak", 1)
        setenv("DYLD_INSERT_LIBRARIES", "/evil.dylib", 1)
        defer {
            unsetenv("LLAMA_ARG_API_KEY")
            unsetenv("DYLD_INSERT_LIBRARIES")
        }
        let rig = try makeRig(script: "/usr/bin/env\nexec sleep 60")
        await rig.launch.start(using: rig.server)
        await waitUntil { ((try? String(contentsOf: rig.logURL, encoding: .utf8)) ?? "").contains("TMPDIR=") }
        // The program's output is the log.
        let names = (try String(contentsOf: rig.logURL, encoding: .utf8))
            .split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) }
        await rig.launch.stop(using: rig.server)
        #expect(Set(names).isSuperset(of: ["PATH", "HOME", "TMPDIR"]))
        #expect(Set(names).subtracting(["PATH", "HOME", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD"]).isEmpty)
    }
}
