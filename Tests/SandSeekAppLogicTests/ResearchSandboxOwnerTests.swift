import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

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
                            baseURL: URL? = nil) throws -> ResearchSandboxController {
        ResearchSandboxController(
            baseURL: baseURL, runner: runner, containerTool: .trustedForTests(),
            transport: FakeResearchServices(), defaults: MemorySettings(),
            environment: [:], resources: try testResources(),
            stateDirectory: temporaryDirectory(), secretFile: secret)
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
        #expect(sandbox.state == .failed("Another SandSeek is using the web sandbox. Close it first."))
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
            status: 75, output: "Another SandSeek is using the web sandbox. Close it first.\n")
        #expect(ResearchSandboxController.message(for: busy, doing: "start the sandbox")
            == "Another SandSeek is using the web sandbox. Close it first.")
        let other = ResearchProcessResult(status: 1, output: "boom\n")
        #expect(ResearchSandboxController.message(for: other, doing: "start the sandbox")
            .hasPrefix("Could not start the sandbox"))
    }

    @Test func aRestartReplacesTheAppsOwnSandboxAndNoOtherStartDoes() async throws {
        let (_, secret) = try sandboxFolder()
        let runner = FakeProcessRunner()
        let sandbox = try controller(secret: secret, runner: runner)
        await sandbox.start()
        #expect(await sandbox.restart())
        let starts = zip(runner.commands, runner.environments)
            .filter { $0.0.first == "bash" && $0.0.last == "start" }.map { $0.1 }
        #expect(starts.count == 2)
        #expect(starts[0]["SANDSEEK_SANDBOX_REPLACE"] == nil)
        #expect(starts[1]["SANDSEEK_SANDBOX_REPLACE"] == "1")
        #expect(runner.scriptCommands.filter { $0 == "stop" }.isEmpty)
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
