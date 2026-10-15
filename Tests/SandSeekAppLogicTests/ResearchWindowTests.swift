import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

// MARK: - Folding the cards

@Suite struct ResearchCardFoldingTests {
    private typealias Folds = ResearchCardFolding.Folds
    private let unfolded = Folds(server: false, sandbox: false)
    private let folded = Folds(server: true, sandbox: true)

    private func readiness(_ server: Bool?, _ sandbox: Bool?) -> ResearchCardReadiness {
        ResearchCardReadiness(server: server, sandbox: sandbox)
    }

    @Test func bothCardsFoldOnceWhenBothAreReady() {
        var folding = ResearchCardFolding()
        // One of them ready is not enough.
        #expect(folding.update(readiness(true, false), folds: unfolded) == unfolded)
        #expect(folding.update(readiness(true, true), folds: unfolded) == folded)
    }

    @Test func aCardTheUserOpensStaysOpenWhileBothStayReady() {
        var folding = ResearchCardFolding()
        var folds = folding.update(readiness(true, true), folds: unfolded)
        #expect(folds == folded)
        folds.sandbox = false
        // The periodic look reports the same readiness again and again.
        for _ in 0..<3 {
            folds = folding.update(readiness(true, true), folds: folds)
        }
        #expect(folds == Folds(server: true, sandbox: false))
    }

    @Test func aCardThatStopsBeingReadyOpensAndTheOtherStaysAsItIs() {
        var folding = ResearchCardFolding()
        var folds = folding.update(readiness(true, true), folds: unfolded)
        folds = folding.update(readiness(false, true), folds: folds)
        #expect(folds == Folds(server: false, sandbox: true))
        // Both ready again: both fold once more.
        folds = folding.update(readiness(true, true), folds: folds)
        #expect(folds == folded)
    }

    @Test func aCardThatIsNotReadyOpensEvenIfTheUserFoldedIt() {
        var folding = ResearchCardFolding()
        #expect(folding.update(readiness(false, false), folds: folded) == unfolded)
        #expect(folding.update(readiness(nil, false), folds: folded)
            == Folds(server: true, sandbox: false))
    }

    @Test func aCheckUnderWayChangesNothing() {
        var folding = ResearchCardFolding()
        var folds = folding.update(readiness(true, true), folds: unfolded)
        folds.server = false
        // A Check puts the server in between: the opened card is not folded
        // again when the check ends.
        folds = folding.update(readiness(nil, true), folds: folds)
        #expect(folds == Folds(server: false, sandbox: true))
        folds = folding.update(readiness(true, true), folds: folds)
        #expect(folds == Folds(server: false, sandbox: true))
    }
}

// MARK: - Test rig

/// Holds the sandbox script's `start` and the firewall look (`nft`) while the
/// matching flag is set, so a test can look at the moment in between.
private final class GatedRunner: ResearchProcessRunning, @unchecked Sendable {
    let inner: FakeProcessRunner
    let holdStart = LockedFlag()
    let holdFirewallLook = LockedFlag()

    init(_ inner: FakeProcessRunner) { self.inner = inner }

    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval) async throws -> ResearchProcessResult {
        if arguments.last == "start" {
            while holdStart.value { try await Task.sleep(for: .milliseconds(10)) }
        }
        if arguments.contains("nft") {
            while holdFirewallLook.value { try await Task.sleep(for: .milliseconds(10)) }
        }
        return try await inner.run(executable: executable, arguments: arguments,
                                   environment: environment, timeout: timeout)
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@MainActor private struct Rig {
    let workspace: ResearchWorkspace
    let server: ResearchServerController
    let sandbox: ResearchSandboxController
    let launch: ResearchServerLaunchController
    let launcher: FakeServerLauncher
    let runner: FakeProcessRunner
    let gate: GatedRunner
    let serverServices: FakeResearchServices
    let sandboxServices: FakeResearchServices

    /// The script commands that ran (build, start, stop, selftest).
    var scripts: [String] { runner.scriptCommands }

    /// A workspace whose fakes behave like the real things: the sandbox does
    /// not answer until its `start` script ran, and the self-test passes.
    /// `serverUp`: whether the model server answers at first.
    /// `program`: a TUFFServer is chosen under "Start it from SandSeek".
    /// `startsServer`: starting that program makes the server answer.
    /// `sandboxUp`: the sandbox runs already, without the app having seen it.
    /// `sandboxStartFails`: the `start` script fails.
    static func make(serverUp: Bool = true, program: Bool = false, startsServer: Bool = true,
                     sandboxUp: Bool = false, sandboxStartFails: Bool = false,
                     selfTestFails: Bool = false, firewallMissing: Bool = false,
                     timing: ResearchServerLaunchController.Timing = .init(
                        poll: .milliseconds(5), tuffReady: .milliseconds(100),
                        stopGrace: .milliseconds(100), killGrace: .milliseconds(100))
    ) async throws -> Rig {
        let serverServices = FakeResearchServices(listedModels: ["m"])
        serverServices.setDown(!serverUp)
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "test-key"),
            transport: serverServices, tuffStreaming: false)
        await server.check()

        let launcher = FakeServerLauncher()
        let settings = MemorySettings()
        if program { settings.save("/opt/TUFF/TUFFServer", forKey: "ResearchServerProgram-tuff") }
        let launch = testLaunchController(
            settings: settings,
            launcher: HookedLauncher(inner: launcher, after: {
                if startsServer { serverServices.setDown(false) }
            }),
            transport: serverServices, timing: timing)

        let sandboxServices = FakeResearchServices(sandboxHealthy: sandboxUp)
        let runner = FakeProcessRunner { command in
            if firewallMissing, command.contains("nft") {
                return ResearchProcessResult(status: 1, output: "")
            }
            guard command.first == "bash" else { return FakeProcessRunner.healthy(command) }
            switch command.last {
            case "start":
                if sandboxStartFails { return ResearchProcessResult(status: 1, output: "boom") }
                sandboxServices.setSandboxHealthy(true)
            case "selftest":
                if selfTestFails {
                    return ResearchProcessResult(
                        status: 1, output: "A public page must still work:\n  FAIL  not fetched\n")
                }
                return ResearchProcessResult(
                    status: 0, output: "A public page must still work:\n  ok    fetched\nall sandbox checks passed\n")
            default: break
            }
            return ResearchProcessResult(status: 0, output: "")
        }
        let gate = GatedRunner(runner)
        let sandbox = ResearchSandboxController(
            runner: gate, transport: sandboxServices, defaults: MemorySettings(),
            environment: [:], resources: try testResources(),
            stateDirectory: temporaryDirectory(), secretFile: TestSandboxSecret.file)

        let reports = ResearchReportStore(directory: temporaryDirectory())
        let workspace = ResearchWorkspace(
            sandbox: sandbox, server: server, reports: reports,
            run: ResearchRunController(
                store: reports, transport: FakeResearchServices(),
                sandboxSecretFile: TestSandboxSecret.file),
            presets: ResearchPresetStore(defaults: MemorySettings()), launch: launch)
        return Rig(workspace: workspace, server: server, sandbox: sandbox, launch: launch,
                   launcher: launcher, runner: runner, gate: gate, serverServices: serverServices,
                   sandboxServices: sandboxServices)
    }
}

// MARK: - Start everything

@Suite @MainActor struct ResearchStartEverythingTests {
    @Test func withNoProgramChosenItChecksTheServerThenStartsTheSandboxAndChecksIt() async throws {
        let rig = try await Rig.make(serverUp: false)
        #expect(rig.server.state == .off)
        rig.serverServices.setDown(false)

        await rig.workspace.startEverything()

        #expect(rig.launcher.servers.isEmpty)
        #expect(rig.server.state == .ready)
        #expect(rig.sandbox.state == .ready)
        #expect(rig.sandbox.protection == .verified)
        #expect(rig.scripts == ["build", "start", "selftest"])
        #expect(rig.sandbox.selfTest?.passed == true)
        #expect(rig.workspace.servicesReady)
        #expect(!rig.workspace.isStartingEverything)
        #expect(rig.workspace.startEverythingNote == nil)
    }

    @Test func withAProgramChosenItStartsTheServerFirst() async throws {
        let rig = try await Rig.make(serverUp: false, program: true)
        await rig.workspace.startEverything()

        #expect(rig.launcher.servers.count == 1)
        #expect(rig.launch.state == .running)
        #expect(rig.server.state == .ready)
        #expect(rig.sandbox.state == .ready)
        #expect(rig.scripts == ["build", "start", "selftest"])
    }

    @Test func aServerThatAlreadyAnswersIsNotStartedAgain() async throws {
        let rig = try await Rig.make(serverUp: true, program: true)
        await rig.workspace.startEverything()

        #expect(rig.launcher.servers.isEmpty)
        #expect(rig.launch.state == .idle)
        #expect(rig.server.state == .ready)
        #expect(rig.sandbox.state == .ready)
    }

    @Test func aServerThatAnswersButWasNotSeenYetIsFoundNotStarted() async throws {
        // The card's last look says "off", but the server came up since.
        let rig = try await Rig.make(serverUp: false, program: true)
        #expect(rig.server.state == .off)
        rig.serverServices.setDown(false)
        await rig.workspace.startEverything()

        #expect(rig.launcher.servers.isEmpty)
        #expect(rig.server.state == .ready)
    }

    @Test func everythingAlreadyReadyStartsNothingAndSkipsAPassedSecurityCheck() async throws {
        let rig = try await Rig.make(serverUp: true, program: true)
        await rig.sandbox.start()
        await rig.sandbox.runSelfTest()
        #expect(rig.scripts == ["build", "start", "selftest"])

        await rig.workspace.startEverything()
        #expect(rig.launcher.servers.isEmpty)
        #expect(rig.scripts == ["build", "start", "selftest"])
        #expect(!rig.workspace.showsStartEverything)
    }

    @Test func aSandboxThatAlreadyRunsIsNotStartedAgain() async throws {
        let rig = try await Rig.make(serverUp: true, sandboxUp: true)
        #expect(rig.sandbox.state == .off)

        await rig.workspace.startEverything()
        #expect(rig.sandbox.state == .ready)
        // Found by the look; only the security check ran a script.
        #expect(rig.scripts == ["selftest"])
    }

    @Test func aFailedServerStartStopsBeforeTheSandbox() async throws {
        let rig = try await Rig.make(serverUp: false, program: true, startsServer: false)
        await rig.workspace.startEverything()

        guard case .failed = rig.launch.state else {
            Issue.record("expected a failed start, got \(rig.launch.state)")
            return
        }
        #expect(rig.server.state != .ready)
        #expect(rig.sandbox.state == .off)
        #expect(rig.scripts.isEmpty)
        #expect(!rig.workspace.isStartingEverything)
        #expect(rig.workspace.showsStartEverything)
    }

    @Test func aServerThatDoesNotAnswerStopsBeforeTheSandbox() async throws {
        let rig = try await Rig.make(serverUp: false)
        await rig.workspace.startEverything()

        #expect(rig.server.state == .off)
        #expect(rig.launcher.servers.isEmpty)
        #expect(rig.sandbox.state == .off)
        #expect(rig.scripts.isEmpty)
    }

    @Test func aSandboxThatFailsToStartStopsBeforeTheSecurityCheck() async throws {
        let rig = try await Rig.make(serverUp: true, sandboxStartFails: true)
        await rig.workspace.startEverything()

        guard case .failed = rig.sandbox.state else {
            Issue.record("expected a failed sandbox, got \(rig.sandbox.state)")
            return
        }
        #expect(rig.sandbox.selfTest == nil)
        #expect(!rig.scripts.contains("selftest"))
    }

    @Test func twoClicksStartOnlyOneSandbox() async throws {
        let rig = try await Rig.make(serverUp: true)
        let first = Task { await rig.workspace.startEverything() }
        await rig.workspace.startEverything()
        await first.value

        #expect(rig.scripts.filter { $0 == "start" }.count == 1)
        #expect(rig.scripts.filter { $0 == "build" }.count == 1)
        #expect(rig.sandbox.state == .ready)
    }

    @Test func aSandboxStartedMeanwhileIsWaitedForNotStartedAgain() async throws {
        let rig = try await Rig.make(serverUp: true)
        // The Start Sandbox button was clicked a moment before, and its VM is
        // not up yet.
        rig.gate.holdStart.value = true
        let starting = Task { await rig.sandbox.start() }
        await waitUntil { rig.sandbox.state.isBusy }
        #expect(rig.sandbox.state.isBusy)

        let everything = Task { await rig.workspace.startEverything() }
        await waitUntil { rig.workspace.isStartingEverything }
        // It really waits: no second start, and it has not finished.
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.workspace.isStartingEverything)
        #expect(rig.sandbox.state.isBusy)
        #expect(!rig.scripts.contains("start"))

        rig.gate.holdStart.value = false
        await starting.value
        await everything.value

        #expect(rig.scripts.filter { $0 == "start" }.count == 1)
        #expect(rig.sandbox.state == .ready)
        #expect(rig.sandbox.selfTest?.passed == true)
        #expect(rig.workspace.startEverythingStopNote == nil)
    }

    @Test func aProtectionCheckUnderWayIsWaitedForNotSkipped() async throws {
        // The periodic look found the sandbox and is checking its firewall.
        let rig = try await Rig.make(serverUp: true, sandboxUp: true)
        rig.gate.holdFirewallLook.value = true
        let looking = Task { await rig.sandbox.refresh() }
        await waitUntil { rig.sandbox.protection == .checking }
        #expect(rig.sandbox.protection == .checking)

        let everything = Task { await rig.workspace.startEverything() }
        await waitUntil { rig.workspace.isStartingEverything }
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.workspace.isStartingEverything)
        #expect(rig.sandbox.selfTest == nil)

        rig.gate.holdFirewallLook.value = false
        await looking.value
        await everything.value

        #expect(rig.sandbox.protection == .verified)
        #expect(rig.sandbox.selfTest?.passed == true)
        #expect(rig.workspace.startEverythingStopNote == nil)
        // Found by the look, not started: only the security check ran a script.
        #expect(rig.scripts == ["selftest"])
    }

    @Test func everyStopSaysWhy() async throws {
        let noServer = try await Rig.make(serverUp: false)
        await noServer.workspace.startEverything()
        #expect(noServer.workspace.startEverythingStopNote?.contains("model server") == true)

        let failedStart = try await Rig.make(serverUp: false, program: true, startsServer: false)
        await failedStart.workspace.startEverything()
        #expect(failedStart.workspace.startEverythingStopNote?.contains("did not start") == true)

        let noSandbox = try await Rig.make(serverUp: true, sandboxStartFails: true)
        await noSandbox.workspace.startEverything()
        #expect(noSandbox.workspace.startEverythingStopNote?.contains("sandbox") == true)

        let unverified = try await Rig.make(serverUp: true, firewallMissing: true)
        await unverified.workspace.startEverything()
        #expect(unverified.workspace.startEverythingStopNote?.contains("not verified") == true)
        #expect(!unverified.scripts.contains("selftest"))

        let unsafe = try await Rig.make(serverUp: true, selfTestFails: true)
        await unsafe.workspace.startEverything()
        #expect(unsafe.workspace.startEverythingStopNote?.contains("security check") == true)

        // A run that gets through clears the note, and so does a new run.
        let fine = try await Rig.make(serverUp: true)
        await fine.workspace.startEverything()
        #expect(fine.workspace.startEverythingStopNote == nil)
    }

    @Test func theButtonShowsOnlyWhileSomethingIsNotReady() async throws {
        let rig = try await Rig.make(serverUp: true)
        #expect(rig.workspace.showsStartEverything)
        #expect(rig.workspace.canStartEverything)
        await rig.workspace.startEverything()
        #expect(rig.workspace.servicesReady)
        #expect(!rig.workspace.showsStartEverything)
    }
}

// MARK: - What the folding sees

@Suite @MainActor struct ResearchCardReadinessTests {
    @Test func readinessFollowsTheTwoServices() async throws {
        let rig = try await Rig.make(serverUp: true)
        #expect(rig.workspace.cardReadiness == ResearchCardReadiness(server: true, sandbox: false))

        await rig.sandbox.start()
        #expect(rig.workspace.cardReadiness == ResearchCardReadiness(server: true, sandbox: true))

        rig.serverServices.setDown(true)
        await rig.server.refresh()
        #expect(rig.workspace.cardReadiness == ResearchCardReadiness(server: false, sandbox: true))
    }

    @Test func aSandboxWhoseProtectionFailedCountsAsNotReady() async throws {
        let rig = try await Rig.make(serverUp: true)
        // The firewall is not loaded.
        let runner = FakeProcessRunner { command in
            command.contains("nft")
                ? ResearchProcessResult(status: 1, output: "")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = ResearchSandboxController(
            runner: runner, transport: FakeResearchServices(), defaults: MemorySettings(),
            environment: [:], resources: try testResources(),
            stateDirectory: temporaryDirectory(), secretFile: TestSandboxSecret.file)
        let workspace = ResearchWorkspace(
            sandbox: sandbox, server: rig.server, reports: rig.workspace.reports,
            run: rig.workspace.run, presets: rig.workspace.presets, launch: rig.launch)
        await sandbox.start()
        guard case .notVerified = sandbox.protection else {
            Issue.record("expected an unverified sandbox, got \(sandbox.protection)")
            return
        }
        #expect(workspace.cardReadiness.sandbox == false)
    }
}

@Suite @MainActor struct ResearchFailedCheckTests {
    @Test func aFailedSecurityCheckOpensTheCardAndTakesTheSeal() async throws {
        let rig = try await Rig.make(serverUp: true, selfTestFails: true)
        await rig.workspace.startEverything()

        #expect(rig.sandbox.state == .ready)
        #expect(rig.sandbox.protection == .verified)
        #expect(rig.sandbox.securityCheckFailed)
        #expect(!rig.sandbox.showsSignedSeal)
        #expect(rig.workspace.cardReadiness.sandbox == false)

        // Folded cards open for it, and a passing check closes the case.
        let folded = ResearchCardFolding.Folds(server: true, sandbox: true)
        #expect(rig.workspace.foldsAfterReadinessChange(current: folded).sandbox == false)
    }

    @Test func aPassingCheckShowsTheSealOnlyWhileVerified() async throws {
        let rig = try await Rig.make(serverUp: true)
        await rig.sandbox.start()
        #expect(rig.sandbox.showsSignedSeal)
        #expect(!rig.sandbox.securityCheckFailed)
        await rig.sandbox.stop()
        #expect(!rig.sandbox.showsSignedSeal)
    }

    @Test func noSealWhileTheProtectionIsNotVerified() async throws {
        let rig = try await Rig.make(serverUp: true, firewallMissing: true)
        await rig.sandbox.start()
        #expect(rig.sandbox.state == .ready)
        #expect(rig.sandbox.lastSignedCheck != nil)
        #expect(!rig.sandbox.showsSignedSeal)
    }

    @Test func foldingMemoryLivesInTheWorkspace() async throws {
        let rig = try await Rig.make(serverUp: true)
        await rig.sandbox.start()
        let open = ResearchCardFolding.Folds(server: false, sandbox: false)
        let folded = rig.workspace.foldsAfterReadinessChange(current: open)
        #expect(folded == ResearchCardFolding.Folds(server: true, sandbox: true))

        // The person opens the sandbox card; leaving the screen and coming
        // back asks again with the same readiness and must not fold it.
        let opened = ResearchCardFolding.Folds(server: true, sandbox: false)
        #expect(rig.workspace.foldsAfterReadinessChange(current: opened) == opened)
    }
}

// MARK: - The sandbox's last signed check

@Suite @MainActor struct ResearchSandboxCheckTimeTests {
    private func makeSandbox(_ services: FakeResearchServices, clock: FakeClock) throws
        -> ResearchSandboxController {
        ResearchSandboxController(
            runner: FakeProcessRunner(), transport: services, defaults: MemorySettings(),
            environment: [:], resources: try testResources(),
            stateDirectory: temporaryDirectory(), secretFile: TestSandboxSecret.file,
            now: { clock.now })
    }

    @Test func aPassingSignedCheckIsTimestamped() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
        let sandbox = try makeSandbox(FakeResearchServices(), clock: clock)
        #expect(sandbox.lastSignedCheck == nil)

        await sandbox.refresh()
        #expect(sandbox.state == .ready)
        #expect(sandbox.lastSignedCheck == Date(timeIntervalSince1970: 1_700_000_000))

        clock.advance(by: 60)
        await sandbox.refresh()
        #expect(sandbox.lastSignedCheck == Date(timeIntervalSince1970: 1_700_000_060))
        #expect(sandbox.lastCheckFailure == nil)
    }

    @Test func aFailedCheckClearsTheTimeAndSaysSo() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
        let services = FakeResearchServices()
        let sandbox = try makeSandbox(services, clock: clock)
        await sandbox.refresh()
        #expect(sandbox.state == .ready)

        services.setSandboxHealthy(false)
        clock.advance(by: 30)
        await sandbox.refresh()
        #expect(sandbox.state == .off)
        #expect(sandbox.lastSignedCheck == nil)
        #expect(sandbox.lastCheckFailure?.isEmpty == false)

        // Back again: the note goes and the time is the new one.
        services.setSandboxHealthy(true)
        clock.advance(by: 30)
        await sandbox.refresh()
        #expect(sandbox.state == .ready)
        #expect(sandbox.lastCheckFailure == nil)
        #expect(sandbox.lastSignedCheck == Date(timeIntervalSince1970: 1_700_000_060))
    }

    @Test func aSandboxThatNeverRanHasNoTimeAndNoFailure() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
        let sandbox = try makeSandbox(FakeResearchServices(sandboxHealthy: false), clock: clock)
        await sandbox.refresh()
        #expect(sandbox.state == .off)
        #expect(sandbox.lastSignedCheck == nil)
        #expect(sandbox.lastCheckFailure == nil)
    }

    @Test func startingTheSandboxTimestampsItsFirstCheck() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
        let sandbox = try makeSandbox(FakeResearchServices(), clock: clock)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(sandbox.lastSignedCheck == Date(timeIntervalSince1970: 1_700_000_000))
        await sandbox.stop()
        #expect(sandbox.lastSignedCheck == nil)
    }

    @Test func theTimeIsShownAsHoursAndMinutes() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let british = Locale(identifier: "en_GB")
        #expect(ResearchSandboxController.checkedLabel(
            for: Date(timeIntervalSince1970: 1_700_000_000), timeZone: utc,
            locale: british) == "checked 22:13")
        #expect(ResearchSandboxController.checkedLabel(
            for: Date(timeIntervalSince1970: 1_700_000_000 + 11 * 3_600 + 3 * 60),
            timeZone: utc, locale: british) == "checked 09:16")
    }

    @Test func theFailureTextSaysWhatHappenedInOneSentence() {
        #expect(ResearchSandboxController.checkFailureText(nil) == "The sandbox stopped answering.")
        #expect(ResearchSandboxController.checkFailureText(.sandboxUnavailable("refused"))
            == "The sandbox stopped answering.")
        #expect(ResearchSandboxController.checkFailureText(.sandboxNotSigned(address: "127.0.0.1:9100"))
            .contains("without SandSeek"))
        #expect(ResearchSandboxController.checkFailureText(.sandboxWrongVersion)
            .hasPrefix("The sandbox check failed."))
    }
}

// MARK: - Copy answer

@Suite struct ResearchPlainAnswerTests {
    @Test func theCopiedAnswerHasNoFormattingMarksAndNoLinks() {
        let text = ResearchAnswerFormatter.plainText(
            "## Result\nThe **tower** is 300 m tall [1]. See [docs](https://evil.example).")
        #expect(text == "Result\nThe tower is 300 m tall [1]. See docs.")
    }
}
