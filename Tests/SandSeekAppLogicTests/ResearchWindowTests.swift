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
            guard command.first == "bash" else { return FakeProcessRunner.healthy(command) }
            switch command.last {
            case "start":
                if sandboxStartFails { return ResearchProcessResult(status: 1, output: "boom") }
                sandboxServices.setSandboxHealthy(true)
            case "selftest":
                return ResearchProcessResult(
                    status: 0, output: "A public page must still work:\n  ok    fetched\nall sandbox checks passed\n")
            default: break
            }
            return ResearchProcessResult(status: 0, output: "")
        }
        let sandbox = ResearchSandboxController(
            runner: runner, transport: sandboxServices, defaults: MemorySettings(),
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
                   launcher: launcher, runner: runner, serverServices: serverServices,
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
        // The Start Sandbox button was clicked a moment before.
        let starting = Task { await rig.sandbox.start() }
        await waitUntil { rig.sandbox.state.isBusy }
        await rig.workspace.startEverything()
        await starting.value

        #expect(rig.scripts.filter { $0 == "start" }.count == 1)
        #expect(rig.sandbox.state == .ready)
        #expect(rig.sandbox.selfTest?.passed == true)
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

// MARK: - The sandbox's last signed check

@Suite @MainActor struct ResearchSandboxCheckTimeTests {
    private func sandbox(_ services: FakeResearchServices, clock: FakeClock) throws
        -> ResearchSandboxController {
        ResearchSandboxController(
            runner: FakeProcessRunner(), transport: services, defaults: MemorySettings(),
            environment: [:], resources: try testResources(),
            stateDirectory: temporaryDirectory(), secretFile: TestSandboxSecret.file,
            now: { clock.now })
    }

    @Test func aPassingSignedCheckIsTimestamped() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
        let sandbox = try sandbox(FakeResearchServices(), clock: clock)
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
        let sandbox = try sandbox(services, clock: clock)
        await sandbox.refresh()
        #expect(sandbox.state == .ready)

        services.setSandboxHealthy(false)
        clock.advance(by: 30)
        await sandbox.refresh()
        #expect(sandbox.state == .off)
        #expect(sandbox.lastSignedCheck == nil)
        #expect(sandbox.lastCheckFailure?.contains("stopped passing its signed check") == true)

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
        let sandbox = try sandbox(FakeResearchServices(sandboxHealthy: false), clock: clock)
        await sandbox.refresh()
        #expect(sandbox.state == .off)
        #expect(sandbox.lastSignedCheck == nil)
        #expect(sandbox.lastCheckFailure == nil)
    }

    @Test func startingTheSandboxTimestampsItsFirstCheck() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_700_000_000))
        let sandbox = try sandbox(FakeResearchServices(), clock: clock)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(sandbox.lastSignedCheck == Date(timeIntervalSince1970: 1_700_000_000))
        await sandbox.stop()
        #expect(sandbox.lastSignedCheck == nil)
    }

    @Test func theTimeIsShownAsHoursAndMinutes() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ResearchSandboxController.checkedLabel(
            for: Date(timeIntervalSince1970: 1_700_000_000), timeZone: utc) == "checked 22:13")
        #expect(ResearchSandboxController.checkedLabel(
            for: Date(timeIntervalSince1970: 1_700_000_000 + 11 * 3_600 + 3 * 60),
            timeZone: utc) == "checked 09:16")
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
