import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// Stands in for the lock holder `research_sandbox.sh start` leaves running:
/// `take()` lets go of the lock it holds and takes it again, as the script's
/// start does when the app replaces its own VM.
final class FakeLockHolder: @unchecked Sendable {
    private let guardLock = NSLock()
    private var held: ResearchSandboxLock?
    let file: URL
    let pid: Int32

    init(file: URL, pid: Int32 = getpid()) {
        self.file = file
        self.pid = pid
    }

    func take() {
        guardLock.withLock {
            held?.release()
            held = ResearchSandboxLock.acquire(at: file, pid: pid)
        }
    }

    func release() {
        guardLock.withLock {
            held?.release()
            held = nil
        }
    }

    /// A runner whose `start` takes the lock, as the real script does.
    func runner(startStatus: Int32 = 0) -> FakeProcessRunner {
        FakeProcessRunner { [self] command in
            if command.first == "bash", command.last == "start" {
                take()
                return ResearchProcessResult(status: startStatus, output: "")
            }
            return FakeProcessRunner.healthy(command)
        }
    }
}

/// One SandSeek at a time: the lock, the port and the VM name that each start
/// records beside the secret, and the removal of leftover VMs (the script does
/// that under the lock; see Scripts/test_research_sandbox.py).
@Suite @MainActor struct ResearchSandboxOwnerTests {
    /// A sandbox folder like the launcher's, with the test secret in it.
    private func sandboxFolder() throws -> (folder: URL, secret: URL) {
        let folder = temporaryDirectory("SandSeekOwner")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let secret = folder.appendingPathComponent("secret")
        try Data(TestSandboxSecret.text.utf8).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        return (folder, secret)
    }

    /// Writes a file the way the launcher does (mode 0600).
    private func record(_ text: String, as name: String, in folder: URL) throws {
        let file = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func controller(secret: URL, runner: FakeProcessRunner = FakeProcessRunner(),
                            baseURL: URL? = nil,
                            services: FakeResearchServices = FakeResearchServices(),
                            bundle: URL? = nil,
                            stateDirectory: URL = temporaryDirectory(),
                            isLockHolder: @escaping @Sendable (Int32, URL) -> Bool = { _, _ in true }
    ) throws -> ResearchSandboxController {
        ResearchSandboxController(
            baseURL: baseURL, runner: runner, containerTool: .trustedForTests(),
            transport: services, defaults: MemorySettings(),
            environment: [:], resources: try testResources(bundle: bundle),
            stateDirectory: stateDirectory, secretFile: secret, lockHolderCheck: isLockHolder)
    }

    private func markerFile(in state: URL) -> URL {
        state.appendingPathComponent("sandbox-started-by-app")
    }

    @Test func theSandboxIsFoundOnThePortTheLastStartRecorded() throws {
        let (folder, secret) = try sandboxFolder()
        let sandbox = try controller(secret: secret)
        #expect(sandbox.baseURL.absoluteString == "http://127.0.0.1:9100")
        try record("49152\n", as: "port", in: folder)
        #expect(sandbox.baseURL.absoluteString == "http://127.0.0.1:49152")
        // A new start picks another port; the controller reads it again.
        try record("50123\n", as: "port", in: folder)
        #expect(sandbox.baseURL.port == 50_123)
    }

    @Test func aGivenAddressWinsOverTheRecord() throws {
        let (folder, secret) = try sandboxFolder()
        try record("49152\n", as: "port", in: folder)
        let fixed = URL(string: "http://127.0.0.1:9555")!
        #expect(try controller(secret: secret, baseURL: fixed).baseURL == fixed)
    }

    @Test func theScriptIsNeverHandedAPortToUse() async throws {
        let (folder, secret) = try sandboxFolder()
        try record("49152\n", as: "port", in: folder)
        let runner = FakeProcessRunner()
        let sandbox = ResearchSandboxController(
            runner: runner, containerTool: .trustedForTests(), transport: FakeResearchServices(),
            defaults: MemorySettings(), environment: ["SANDSEEK_SANDBOX_PORT": "9555"],
            resources: try testResources(), stateDirectory: temporaryDirectory(), secretFile: secret)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(runner.environments.allSatisfy { $0["SANDSEEK_SANDBOX_PORT"] == nil })
        // Nor does the exported port decide where the app looks.
        #expect(sandbox.baseURL.port == 49_152)
    }

    @Test func theProtectionCheckEntersTheVMTheStartNamed() async throws {
        let (folder, secret) = try sandboxFolder()
        try record("sandseek-sandbox-0123abcd\n", as: "vm-name", in: folder)
        let runner = FakeProcessRunner()
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.refresh()
        #expect(sandbox.state == .ready)
        #expect(sandbox.protection == .verified)
        let entered = runner.commands.filter { $0.starts(with: ["container", "exec"]) }
        #expect(!entered.isEmpty)
        #expect(entered.allSatisfy { $0[2] == "sandseek-sandbox-0123abcd" })
    }

    @Test func withoutARecordedNameItIsTheOldPlainName() async throws {
        let (_, secret) = try sandboxFolder()
        let runner = FakeProcessRunner()
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.refresh()
        #expect(runner.commands.contains {
            $0.starts(with: ["container", "exec", "sandseek-sandbox", "nft"])
        })
    }

    @Test func aStartWhileAnotherSandSeekHoldsTheLockSaysSoAndBuildsNothing() async throws {
        let (folder, secret) = try sandboxFolder()
        let runner = FakeProcessRunner()
        let sandbox = try controller(secret: secret, runner: runner)
        let lock = try #require(ResearchSandboxLock.acquire(
            at: ResearchSandboxFiles.lockFile(in: folder)))
        await sandbox.start()
        #expect(sandbox.state == .failed("Another SandSeek is using the web sandbox. Close it first, or press Stop in it."))
        #expect(runner.commands.isEmpty)
        #expect(!sandbox.startedByApp)

        // Once the other one lets go (the lock is held until here), the same
        // controller starts.
        lock.release()
        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(runner.scriptCommands == ["build", "start"])
    }

    @Test func aLockLeftByAProcessThatIsGoneDoesNotStopAStart() async throws {
        let (folder, secret) = try sandboxFolder()
        try record("2000000000 1700000000\n", as: "lock", in: folder)
        let runner = FakeProcessRunner()
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(runner.scriptCommands == ["build", "start"])
    }

    @Test func theScriptsBusyAnswerIsShownAsPlainWords() {
        let busy = ResearchProcessResult(
            status: 75, output: "Another SandSeek is using the web sandbox. Close it first, or press Stop in it.\n")
        #expect(ResearchSandboxController.message(for: busy, doing: "start the sandbox")
            == "Another SandSeek is using the web sandbox. Close it first, or press Stop in it.")
        let other = ResearchProcessResult(status: 1, output: "boom\n")
        #expect(ResearchSandboxController.message(for: other, doing: "start the sandbox")
            .hasPrefix("Could not start the sandbox"))
    }

    @Test func aRestartReplacesTheAppsOwnSandboxAndNoOtherStartDoes() async throws {
        let (folder, secret) = try sandboxFolder()
        let holder = FakeLockHolder(file: ResearchSandboxFiles.lockFile(in: folder))
        defer { holder.release() }
        let runner = holder.runner()
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        #expect(sandbox.ownedHolderPid == getpid())
        #expect(await sandbox.restart())
        let starts = zip(runner.commands, runner.environments)
            .filter { $0.0.first == "bash" && $0.0.last == "start" }.map { $0.1 }
        #expect(starts.count == 2)
        // The first start is told nothing; the restart names the holder the
        // app recorded after its own start, not a bare "yes".
        #expect(starts[0]["SANDSEEK_SANDBOX_REPLACE"] == nil)
        #expect(starts[1]["SANDSEEK_SANDBOX_REPLACE"] == String(getpid()))
        #expect(runner.scriptCommands.filter { $0 == "stop" }.isEmpty)
    }

    @Test func theMarkerKeepsTheHolderOfTheAppsOwnStartAcrossARestartOfTheApp() async throws {
        let (folder, secret) = try sandboxFolder()
        let holder = FakeLockHolder(file: ResearchSandboxFiles.lockFile(in: folder))
        defer { holder.release() }
        let state = temporaryDirectory()
        let sandbox = try controller(secret: secret, runner: holder.runner(), stateDirectory: state)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(try String(contentsOf: markerFile(in: state), encoding: .utf8) == "\(getpid())\n")
        // The app quit without a clean stop and starts again.
        let again = try controller(secret: secret, stateDirectory: state)
        #expect(again.startedByApp)
        #expect(again.ownedHolderPid == getpid())
        // A marker from before the holder was recorded still counts as started.
        try Data().write(to: markerFile(in: state))
        let legacy = try controller(secret: secret, stateDirectory: state)
        #expect(legacy.startedByApp)
        #expect(legacy.ownedHolderPid == nil)
    }

    @Test func aRestartLeavesAnotherSandSeeksSandboxAlone() async throws {
        let (folder, secret) = try sandboxFolder()
        let lockFile = ResearchSandboxFiles.lockFile(in: folder)
        let holder = FakeLockHolder(file: lockFile)
        defer { holder.release() }
        let state = temporaryDirectory()
        let runner = holder.runner()
        let sandbox = try controller(secret: secret, runner: runner, stateDirectory: state)
        await sandbox.start()
        let before = runner.scriptCommands
        // Another SandSeek replaced this VM and now holds the lock.
        holder.release()
        let other = try #require(ResearchSandboxLock.acquire(at: lockFile, pid: 4242))
        defer { other.release() }
        #expect(await sandbox.restart() == false)
        #expect(sandbox.state == .failed(ResearchSandboxLock.busyMessage))
        #expect(runner.scriptCommands == before)
        #expect(!sandbox.startedByApp)
        #expect(sandbox.ownedHolderPid == nil)
        #expect(!FileManager.default.fileExists(atPath: markerFile(in: state).path))
    }

    @Test func stopLeavesASandboxThatAnotherSandSeekHoldsAlone() async throws {
        let (folder, secret) = try sandboxFolder()
        let lockFile = ResearchSandboxFiles.lockFile(in: folder)
        let holder = FakeLockHolder(file: lockFile)
        defer { holder.release() }
        let runner = holder.runner()
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        holder.release()
        let other = try #require(ResearchSandboxLock.acquire(at: lockFile, pid: 4242))
        defer { other.release() }
        await sandbox.stop()
        #expect(!runner.scriptCommands.contains("stop"))
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a note, got \(sandbox.state)")
            return
        }
        #expect(message.contains("another SandSeek"))
        #expect(!sandbox.startedByApp)
        // A sandbox nobody holds the lock for (its holder is gone) is stopped.
        let alone = try controller(secret: secret, runner: runner)
        other.release()
        await alone.stop()
        #expect(runner.scriptCommands.contains("stop"))
    }

    @Test func quittingStopsOnlyTheSandboxTheAppHoldsTheLockFor() async throws {
        let (folder, secret) = try sandboxFolder()
        let lockFile = ResearchSandboxFiles.lockFile(in: folder)
        // A script that leaves a trace when it runs.
        let bundle = try fakeSandboxBundle()
        let script = bundle.appendingPathComponent("Scripts/research_sandbox.sh")
        try Data("#!/bin/bash\ntouch \"$0.ran\"\n".utf8).write(to: script)
        let ran = URL(fileURLWithPath: script.path + ".ran")
        let holder = FakeLockHolder(file: lockFile)
        defer { holder.release() }
        let state = temporaryDirectory()
        let sandbox = try controller(
            secret: secret, runner: holder.runner(), bundle: bundle, stateDirectory: state)
        await sandbox.start()
        #expect(sandbox.startedByApp)
        holder.release()
        let other = try #require(ResearchSandboxLock.acquire(at: lockFile, pid: 4242))
        defer { other.release() }
        sandbox.stopWhenQuitting()
        #expect(!FileManager.default.fileExists(atPath: ran.path))
        #expect(!sandbox.startedByApp)
        #expect(!FileManager.default.fileExists(atPath: markerFile(in: state).path))
    }

    @Test func quittingRunsTheStopForTheAppsOwnHolder() async throws {
        let (folder, secret) = try sandboxFolder()
        let bundle = try fakeSandboxBundle()
        let script = bundle.appendingPathComponent("Scripts/research_sandbox.sh")
        try Data("#!/bin/bash\ntouch \"$0.ran\"\n".utf8).write(to: script)
        let holder = FakeLockHolder(file: ResearchSandboxFiles.lockFile(in: folder))
        defer { holder.release() }
        let sandbox = try controller(secret: secret, runner: holder.runner(), bundle: bundle)
        await sandbox.start()
        sandbox.stopWhenQuitting()
        #expect(FileManager.default.fileExists(atPath: script.path + ".ran"))
    }

    @Test func aStartThatFailsAfterTakingTheLockIsRememberedAndReplacedByTheNext() async throws {
        // The app's time limit kills the script before its cleanup runs: the
        // holder stays. The app records it from the lock and the next start
        // names it.
        let (folder, secret) = try sandboxFolder()
        let lockFile = ResearchSandboxFiles.lockFile(in: folder)
        let holder = FakeLockHolder(file: lockFile)
        defer { holder.release() }
        let failing = holder.runner(startStatus: 1)
        let state = temporaryDirectory()
        let sandbox = try controller(secret: secret, runner: failing, stateDirectory: state,
                                     isLockHolder: { pid, _ in pid == getpid() })
        await sandbox.start()
        guard case .failed = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(sandbox.startedByApp)
        #expect(sandbox.ownedHolderPid == getpid())
        #expect(try String(contentsOf: markerFile(in: state), encoding: .utf8) == "\(getpid())\n")

        // The next start is not refused as busy, and is told which holder to end.
        let working = holder.runner()
        let next = try controller(secret: secret, runner: working, stateDirectory: state)
        #expect(next.ownedHolderPid == getpid())
        await next.start()
        #expect(next.state == .ready)
        let start = zip(working.commands, working.environments)
            .first { $0.0.first == "bash" && $0.0.last == "start" }
        #expect(start?.1["SANDSEEK_SANDBOX_REPLACE"] == String(getpid()))
    }

    @Test func aProcessThatIsNotTheScriptsHolderIsNotRememberedAfterAFailedStart() async throws {
        let (folder, secret) = try sandboxFolder()
        let holder = FakeLockHolder(file: ResearchSandboxFiles.lockFile(in: folder))
        defer { holder.release() }
        let sandbox = try controller(
            secret: secret, runner: holder.runner(startStatus: 1),
            isLockHolder: { _, _ in false })
        await sandbox.start()
        #expect(sandbox.ownedHolderPid == nil)
        #expect(!sandbox.startedByApp)
    }

    @Test func aBusyAnswerLeavesNothingToRemember() async throws {
        let (folder, secret) = try sandboxFolder()
        let holder = FakeLockHolder(file: ResearchSandboxFiles.lockFile(in: folder))
        defer { holder.release() }
        // The script says busy (75) although the app's own check found the lock
        // free; its holder, if any, is somebody else's.
        let runner = FakeProcessRunner { command in
            if command.first == "bash", command.last == "start" {
                holder.take()
                return ResearchProcessResult(status: 75, output: ResearchSandboxLock.busyMessage)
            }
            return FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        #expect(sandbox.state == .failed(ResearchSandboxLock.busyMessage))
        #expect(sandbox.ownedHolderPid == nil)
        #expect(!sandbox.startedByApp)
    }

    @Test func aHolderThatOutlivedTheAppsSandboxStaysRememberedAfterARelaunch() async throws {
        let (folder, secret) = try sandboxFolder()
        let lockFile = ResearchSandboxFiles.lockFile(in: folder)
        let state = temporaryDirectory()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("\(getpid())\n".utf8).write(to: markerFile(in: state))
        let holder = FakeLockHolder(file: lockFile)
        holder.take()
        defer { holder.release() }
        // The sandbox does not answer, but the holder this app started is
        // still there: the marker stays, for Stop and the next start.
        let sandbox = try controller(
            secret: secret, services: FakeResearchServices(sandboxHealthy: false), stateDirectory: state)
        #expect(sandbox.adoptedFromLastRun)
        await sandbox.refresh()
        #expect(sandbox.startedByApp)
        #expect(sandbox.ownedHolderPid == getpid())
        // Once the holder is gone too, the marker goes.
        holder.release()
        let later = try controller(
            secret: secret, services: FakeResearchServices(sandboxHealthy: false), stateDirectory: state)
        await later.refresh()
        #expect(!later.startedByApp)
        #expect(later.ownedHolderPid == nil)
    }

    @Test func stoppingLooksOnlyForTheVMTheAppStarted() async throws {
        let (folder, secret) = try sandboxFolder()
        try record("sandseek-sandbox-0123abcd\n", as: "vm-name", in: folder)
        // Another SandSeek's VM is in the list; ours is not.
        let runner = FakeProcessRunner { command in
            command == ["container", "list", "--all"]
                ? ResearchProcessResult(
                    status: 0, output: "ID                          IMAGE\n"
                        + "sandseek-sandbox-89abcdef   sandseek-sandbox:latest\n")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        await sandbox.stop()
        #expect(sandbox.state == .off)
        #expect(!sandbox.startedByApp)
    }

    @Test func stoppingNamesTheVMThatIsStillThere() async throws {
        let (folder, secret) = try sandboxFolder()
        try record("sandseek-sandbox-0123abcd\n", as: "vm-name", in: folder)
        let runner = FakeProcessRunner { command in
            command == ["container", "list", "--all"]
                ? ResearchProcessResult(
                    status: 0, output: "ID                          IMAGE\n"
                        + "sandseek-sandbox-0123abcd   sandseek-sandbox:latest\n")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        await sandbox.stop()
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(message.contains("still there"))
        #expect(message.contains("container stop sandseek-sandbox-0123abcd"))
        #expect(sandbox.startedByApp)
    }
}

@Suite @MainActor struct ResearchSandboxLeftoverTests {
    @Test func onlyNamesTheStartMakesAreSandboxContainers() {
        for name in ["sandseek-sandbox", "sandseek-sandbox-0123abcd", "sandseek-sandbox-00000000"] {
            #expect(ResearchSandboxController.isSandboxContainer(name), "\(name)")
        }
        for name in ["", "other", "buildkit", "sandseek-sandbox-debug", "sandseek-sandbox-0123ABCD",
                     "sandseek-sandbox-0123abc", "sandseek-sandbox-0123abcde", "sandseek-sandbox:latest",
                     "my-sandseek-sandbox-0123abcd", "sandseek-sandbox-0123abcd-2"] {
            #expect(!ResearchSandboxController.isSandboxContainer(name), "\(name)")
        }
    }

    @Test func theLeftoversAreTheRowsWhoseIDIsASandboxName() {
        let listing = """
        ID                          IMAGE                    OS     STATE
        sandseek-sandbox            sandseek-sandbox:latest  linux  running
        sandseek-sandbox-0123abcd   sandseek-sandbox:latest  linux  stopped
        buildkit                    builder                  linux  running
        mine                        sandseek-sandbox:latest  linux  running
        sandseek-sandbox-debug      sandseek-sandbox:latest  linux  running

        """
        #expect(ResearchSandboxController.sandboxContainers(in: listing)
            == ["sandseek-sandbox", "sandseek-sandbox-0123abcd"])
        #expect(ResearchSandboxController.listsContainer(listing, named: "sandseek-sandbox-0123abcd"))
        #expect(!ResearchSandboxController.listsContainer(listing, named: "sandseek-sandbox-89abcdef"))
        #expect(!ResearchSandboxController.listsContainer("", named: "sandseek-sandbox-0123abcd"))
        #expect(ResearchSandboxController.sandboxContainers(in: "ID IMAGE\n").isEmpty)
    }
}
