import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

@Suite struct ResearchContainerVersionTests {
    @Test func readsTheVersionFromWhatContainerPrints() {
        #expect(ResearchContainerVersion.parse("container CLI version 1.5.0 (build: release, commit: abc1234)")
            == ResearchContainerVersion(major: 1, minor: 5, patch: 0))
        #expect(ResearchContainerVersion.parse("container version 1.10.3\n")
            == ResearchContainerVersion(major: 1, minor: 10, patch: 3))
        // A version without a patch number counts as `.0`.
        #expect(ResearchContainerVersion.parse("container 2.1")
            == ResearchContainerVersion(major: 2, minor: 1, patch: 0))
        #expect(ResearchContainerVersion.parse("") == nil)
        #expect(ResearchContainerVersion.parse("no number here") == nil)
        #expect(ResearchContainerVersion.parse("version 7") == nil)
    }

    @Test func comparesNumbersNotText() {
        func version(_ major: Int, _ minor: Int, _ patch: Int) -> ResearchContainerVersion {
            ResearchContainerVersion(major: major, minor: minor, patch: patch)
        }
        #expect(version(1, 4, 9) < ResearchContainerTool.minimumVersion)
        #expect(version(1, 5, 0) >= ResearchContainerTool.minimumVersion)
        #expect(version(1, 10, 0) > ResearchContainerTool.minimumVersion)
        #expect(version(2, 0, 0) > version(1, 99, 99))
        #expect(version(1, 5, 1) > version(1, 5, 0))
        #expect(version(1, 5, 0).description == "1.5.0")
    }

    @Test func theToolIsPinnedToApplesInstallPathAndTeam() {
        #expect(ResearchContainerTool.installedPath == "/usr/local/bin/container")
        #expect(ResearchContainerTool.minimumVersion.description == "1.5.0")
        #expect(ResearchContainerTool.appleTeamIdentifier == "UPBK2H6LZM")
        #expect(ResearchContainerTool.signatureRequirement
            == "anchor apple generic and certificate leaf[subject.OU] = \"UPBK2H6LZM\"")
    }
}

enum ResearchContainerToolTestPaths {
    static let untrusted = ResearchUntrustedPath(path: "/usr/local/bin", isFolder: true)
}

@Suite struct ResearchContainerVerifyTests {
    static let untrusted = ResearchContainerToolTestPaths.untrusted

    /// A tool whose file checks answer as given and whose `codesign` and
    /// `--version` commands are answered by `reply`.
    private func make(
        trusted: Bool = true, exists: Bool = true,
        reply: @escaping @Sendable ([String]) -> ResearchProcessResult = FakeProcessRunner.healthy
    ) -> (tool: ResearchContainerTool, runner: FakeProcessRunner) {
        let runner = FakeProcessRunner(reply: reply)
        let tool = ResearchContainerTool(
            runner: runner, environment: ["PATH": "/usr/bin"],
            untrustedPath: { _ in trusted ? nil : Self.untrusted }, fileExists: { _ in exists }, identity: { _ in "x" })
        return (tool, runner)
    }

    private func failure(of tool: ResearchContainerTool) async -> ResearchContainerError? {
        do {
            try await tool.verify()
            return nil
        } catch {
            return error as? ResearchContainerError
        }
    }

    @Test func aToolThatIsAppleSignedAndNewEnoughPasses() async throws {
        let (tool, runner) = make()
        let version = try await tool.verify()
        #expect(version == ResearchContainerVersion(major: 1, minor: 5, patch: 0))
        // The signature is checked against Apple's requirement, strictly, on
        // the pinned path, before the tool itself is run.
        #expect(runner.commands.first == [
            "codesign", "--verify", "--strict",
            "-R=anchor apple generic and certificate leaf[subject.OU] = \"UPBK2H6LZM\"",
            "/usr/local/bin/container",
        ])
        #expect(runner.commands.last == ["container", "--version"])
        #expect(runner.executables.first?.path == "/usr/bin/codesign")
        #expect(runner.executables.last?.path == "/usr/local/bin/container")
        // The tool runs with the environment it was given, not the app's.
        #expect(runner.environments.allSatisfy { $0 == ["PATH": "/usr/bin"] })
    }

    @Test func aMissingToolIsNotInstalled() async {
        let (tool, runner) = make(trusted: false, exists: false)
        #expect(await failure(of: tool) == .notInstalled)
        #expect(runner.commands.isEmpty)
    }

    @Test func aToolSomeoneElseCouldChangeIsNotTrustedAndNeverRun() async {
        let (tool, runner) = make(trusted: false, exists: true)
        #expect(await failure(of: tool) == .notTrusted(Self.untrusted))
        #expect(runner.commands.isEmpty)
    }

    @Test func aFailedSignatureCheckIsNotSigned() async {
        let (tool, runner) = make { command in
            command.contains("--verify")
                ? ResearchProcessResult(status: 3, output: "container: code object is not signed at all\n")
                : FakeProcessRunner.healthy(command)
        }
        let error = await failure(of: tool)
        guard case .notSigned(let reason) = error else {
            Issue.record("expected notSigned, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("not signed at all"))
        // The tool itself was not run.
        #expect(!runner.commands.contains(["container", "--version"]))
    }

    @Test func aSignatureCheckThatHangsIsNotSigned() async {
        let (tool, _) = make { command in
            command.contains("--verify")
                ? ResearchProcessResult(status: 15, output: "", timedOut: true)
                : FakeProcessRunner.healthy(command)
        }
        let error = await failure(of: tool)
        guard case .notSigned(let reason) = error else {
            Issue.record("expected notSigned, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("did not answer in time"))
    }

    @Test func anAdHocSignatureIsNotSigned() async {
        let (tool, runner) = make { command in
            command.contains("-dv")
                ? ResearchProcessResult(
                    status: 0, output: "Identifier=container\nSignature=adhoc\nTeamIdentifier=UPBK2H6LZM\n")
                : FakeProcessRunner.healthy(command)
        }
        #expect(await failure(of: tool) == .notSigned(reason: "it is not signed by a developer"))
        #expect(!runner.commands.contains(["container", "--version"]))
    }

    @Test func anotherTeamIsNotSigned() async {
        for details in ["TeamIdentifier=ABCDE12345\n", "TeamIdentifier=not set\n", "Identifier=container\n"] {
            let (tool, _) = make { command in
                command.contains("-dv")
                    ? ResearchProcessResult(status: 0, output: details)
                    : FakeProcessRunner.healthy(command)
            }
            #expect(await failure(of: tool) == .notSigned(reason: "the signer is not Apple's"))
        }
    }

    @Test func anOldVersionIsTooOld() async {
        let (tool, _) = make { command in
            command == ["container", "--version"]
                ? ResearchProcessResult(status: 0, output: "container CLI version 1.4.2\n")
                : FakeProcessRunner.healthy(command)
        }
        #expect(await failure(of: tool) == .tooOld(found: "1.4.2", minimum: "1.5.0"))
    }

    @Test func aVersionThatCannotBeReadIsReported() async {
        let (tool, _) = make { command in
            command == ["container", "--version"]
                ? ResearchProcessResult(status: 0, output: "hello\n")
                : FakeProcessRunner.healthy(command)
        }
        let error = await failure(of: tool)
        guard case .versionUnreadable = error else {
            Issue.record("expected versionUnreadable, got \(String(describing: error))")
            return
        }
    }

    @Test func theMessagesSayWhatToDoInPlainWords() {
        let installed = ResearchContainerError.notInstalled.description
        #expect(installed.contains("Apple container is not installed"))
        #expect(installed.contains("https://github.com/apple/container"))
        #expect(ResearchContainerError.notTrusted(ResearchContainerToolTestPaths.untrusted).description.contains("can be changed"))
        let folder = ResearchContainerError.notTrusted(
            ResearchUntrustedPath(path: "/usr/local/bin", isFolder: true)).description
        #expect(folder.contains("sudo chown root:wheel /usr/local/bin && sudo chmod 755 /usr/local/bin"))
        #expect(folder.contains("Apple's installer does not change this folder"))
        let file = ResearchContainerError.notTrusted(
            ResearchUntrustedPath(path: "/usr/local/bin/container", isFolder: false)).description
        #expect(file.contains("Reinstall it with Apple's installer"))
        #expect(!file.contains("sudo"))
        #expect(ResearchContainerError.notSigned(reason: "the signer is not Apple's").description
            .contains("not signed by Apple"))
        let old = ResearchContainerError.tooOld(found: "1.4.2", minimum: "1.5.0").description
        #expect(old.contains("1.4.2"))
        #expect(old.contains("1.5.0"))
    }

    @Test func aFileAnyoneElseCouldChangeIsNotTrusted() throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("container")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: file.path)
        // Owned by the user running the tests (or world-writable), in a
        // folder under the temporary directory: never root's alone.
        #expect(!ResearchContainerTool.isTrustedFile(file.path))
        // The report names the first path that fails: here the file itself.
        #expect(ResearchContainerTool.firstUntrustedPath(file.path)
            == ResearchUntrustedPath(path: file.resolvingSymlinksInPath().path, isFolder: false))
        #expect(!ResearchContainerTool.isTrustedFile(folder.appendingPathComponent("missing").path))
        // A link in such a folder to a system program does not help.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        #expect(!ResearchContainerTool.isTrustedFile(link.path))
    }

    @Test func aSystemProgramOfRootIsTrusted() {
        #expect(ResearchContainerTool.isTrustedFile("/usr/bin/true"))
    }

    @Test func aFolderIsNotATrustedFile() {
        // Root's and closed, but not a regular file.
        #expect(!ResearchContainerTool.isTrustedFile("/usr/bin"))
    }

    @Test func theIdentityChangesWithTheFileAndIsNilWithoutOne() throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tool")
        try Data("a".utf8).write(to: file)
        let before = try #require(ResearchContainerTool.fileIdentity(file.path))
        try Data("bb".utf8).write(to: file)
        let after = try #require(ResearchContainerTool.fileIdentity(file.path))
        #expect(before != after)
        #expect(ResearchContainerTool.fileIdentity(folder.appendingPathComponent("none").path) == nil)
    }
}

/// A value a test changes while a controller runs.
private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite @MainActor struct ResearchSandboxContainerToolTests {
    private func make(
        runner: FakeProcessRunner = FakeProcessRunner(),
        tool: ResearchContainerTool? = nil,
        environment: [String: String] = [:]
    ) throws -> ResearchSandboxController {
        ResearchSandboxController(
            runner: runner, containerTool: tool ?? .trustedForTests(runner: runner),
            transport: FakeResearchServices(), defaults: MemorySettings(),
            environment: environment, resources: try testResources(),
            stateDirectory: temporaryDirectory(), secretFile: TestSandboxSecret.file)
    }

    @Test func everyContainerCommandUsesTheAbsolutePath() async throws {
        let runner = FakeProcessRunner()
        let sandbox = try make(runner: runner)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        await sandbox.stop()
        #expect(sandbox.state == .off)

        let containerRuns = runner.executables.filter { $0.lastPathComponent == "container" }
        // exec (twice for the protection check), list, image inspect, --version.
        #expect(containerRuns.count >= 4)
        #expect(containerRuns.allSatisfy { $0.path == "/usr/local/bin/container" })
        // No lookup through PATH, and no other program named container.
        #expect(!runner.executables.contains { $0.path == "/usr/bin/env" })
        #expect(runner.executables.allSatisfy { $0.path.hasPrefix("/") })
        #expect(Set(runner.executables.map(\.path)).isSubset(of: [
            "/usr/local/bin/container", "/usr/bin/codesign", "/bin/bash",
        ]))
    }

    @Test func aToolThatIsNotTrustedStopsTheStartBeforeAnythingRuns() async throws {
        let runner = FakeProcessRunner()
        let tool = ResearchContainerTool(
            runner: runner, environment: [:],
            untrustedPath: { _ in ResearchContainerToolTestPaths.untrusted }, fileExists: { _ in true }, identity: { _ in "x" })
        let sandbox = try make(runner: runner, tool: tool)
        await sandbox.start()
        // The reason is the card's message.
        #expect(sandbox.state == .failed(ResearchContainerError.notTrusted(ResearchContainerToolTestPaths.untrusted).description))
        #expect(runner.commands.isEmpty)
        #expect(!sandbox.startedByApp)
    }

    @Test func aMissingToolIsReportedWithWhereToGetIt() async throws {
        let runner = FakeProcessRunner()
        let tool = ResearchContainerTool(
            runner: runner, environment: [:],
            untrustedPath: { _ in ResearchContainerToolTestPaths.untrusted }, fileExists: { _ in false }, identity: { _ in nil })
        let sandbox = try make(runner: runner, tool: tool)
        await sandbox.start()
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(message.contains("Apple container is not installed"))
        #expect(message.contains("https://github.com/apple/container"))
        #expect(runner.commands.isEmpty)
    }

    @Test func aToolThatIsNotAppleSignedStopsTheStart() async throws {
        let runner = FakeProcessRunner { command in
            command.first == "codesign" && command.contains("--verify")
                ? ResearchProcessResult(status: 1, output: "a.out: invalid signature\n")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try make(runner: runner)
        await sandbox.start()
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(message.contains("not signed by Apple"))
        #expect(runner.scriptCommands.isEmpty)
        #expect(!runner.commands.contains { $0.first == "container" })
    }

    @Test func theToolIsCheckedOncePerSessionAndAgainWhenTheFileChanges() async throws {
        let runner = FakeProcessRunner()
        let identity = LockedText("file-1")
        let tool = ResearchContainerTool(
            runner: runner, environment: [:],
            untrustedPath: { _ in nil }, fileExists: { _ in true }, identity: { _ in identity.value })
        let sandbox = try make(runner: runner, tool: tool)
        func checks() -> Int {
            runner.commands.filter { $0.first == "codesign" && $0.contains("--verify") }.count
        }
        await sandbox.start()
        await sandbox.stop()
        await sandbox.start()
        #expect(checks() == 1)

        // The file at the path is another one now: it is checked again.
        identity.value = "file-2"
        await sandbox.stop()
        #expect(checks() == 2)
        await sandbox.start()
        #expect(checks() == 2)
    }

    @Test func aToolThatFailsTheCheckAfterwardsIsNotRunForTheProtectionCheck() async throws {
        let runner = FakeProcessRunner()
        let trusted = LockedFlag()
        trusted.value = true
        let identity = LockedText("file-1")
        let tool = ResearchContainerTool(
            runner: runner, environment: [:],
            untrustedPath: { _ in trusted.value ? nil : ResearchContainerToolTestPaths.untrusted }, fileExists: { _ in true }, identity: { _ in identity.value })
        let sandbox = try make(runner: runner, tool: tool)
        await sandbox.start()
        #expect(sandbox.protection == .verified)
        let before = runner.commands.filter { $0.first == "container" }.count

        // The file was replaced by one anyone can write to.
        trusted.value = false
        identity.value = "file-2"
        await sandbox.recheckProtection()
        #expect(sandbox.protection == .notVerified(ResearchContainerError.notTrusted(ResearchContainerToolTestPaths.untrusted).description))
        #expect(runner.commands.filter { $0.first == "container" }.count == before)
    }

    @Test func theScriptAndContainerGetOnlyAFixedEnvironment() async throws {
        let runner = FakeProcessRunner()
        let shell = [
            "PATH": "/tmp/evil:/usr/bin", "HOME": "/Users/someone", "USER": "someone",
            "LOGNAME": "someone", "TMPDIR": "/var/folders/xx/T/", "LANG": "de_DE.UTF-8",
            "SANDSEEK_DNS": "1.1.1.1", "SEARXNG_URL": "http://127.0.0.1:8080",
            "SANDSEEK_SANDBOX_PORT": "9555", "SANDSEEK_SANDBOX_NAME": "other",
            "SANDSEEK_SOURCE_DIR": "/tmp/x", "BASH_ENV": "/tmp/evil.sh",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "HTTPS_PROXY": "http://proxy.example",
            "SSH_AUTH_SOCK": "/tmp/agent", "OPENAI_API_KEY": "secret",
        ]
        // The tool's own commands (codesign, --version) get the fixed
        // environment without the script's settings.
        let tool = ResearchContainerTool(
            runner: runner, environment: ResearchCommandEnvironment.environment(base: shell),
            untrustedPath: { _ in nil }, fileExists: { _ in true }, identity: { _ in "x" })
        let sandbox = try make(runner: runner, tool: tool, environment: shell)
        await sandbox.start()
        let fixed: Set<String> = ["PATH", "LANG", "HOME", "USER", "LOGNAME", "TMPDIR"]
        let forScript = fixed.union(["SANDSEEK_DNS", "SEARXNG_URL"])
        #expect(runner.commands.count == runner.environments.count)
        #expect(!runner.environments.isEmpty)
        for (command, environment) in zip(runner.commands, runner.environments) {
            let isToolCheck = command.first == "codesign" || command == ["container", "--version"]
            #expect(Set(environment.keys) == (isToolCheck ? fixed : forScript), "\(command)")
            #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
            #expect(environment["LANG"] == "en_US.UTF-8")
            #expect(environment["HOME"] == "/Users/someone")
            if !isToolCheck {
                #expect(environment["SANDSEEK_SANDBOX_PORT"] == nil)
                #expect(environment["SANDSEEK_DNS"] == "1.1.1.1")
                #expect(environment["SEARXNG_URL"] == "http://127.0.0.1:8080")
            }
        }
    }

    @Test func anEmptyEnvironmentGetsOnlyThePathAndLanguage() {
        let environment = ResearchSandboxController.scriptEnvironment([:])
        #expect(environment == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        ])
        // The tool's own commands (codesign, --version) run with no more.
        #expect(ResearchCommandEnvironment.environment(base: [:]) == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        ])
    }
}

@Suite struct ResearchProcessRunnerLimitTests {
    @Test func aCommandThatIgnoresTerminateIsKilledAndSaysItTimedOut() async throws {
        let started = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while true; do sleep 0.2; done"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(result.status != 0)
        // SIGTERM at 0.5 s was ignored; SIGKILL follows 3 s later.
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func aLongGraceLetsCleanupAfterTerminateFinish() async throws {
        // On SIGTERM the command takes a second to clean up, then exits; a
        // grace longer than that means it is not killed halfway.
        let result = try await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap 'sleep 1; echo cleaned; exit 7' TERM; while true; do sleep 0.1; done"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5, killGrace: 10)
        #expect(result.timedOut)
        #expect(result.status == 7)
        #expect(result.output.contains("cleaned"))
    }

    @Test func aCommandThatEndsInTimeDidNotTimeOut() async throws {
        let result = try await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["done"],
            environment: [:], timeout: 30)
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.output == "done\n")
    }

    @Test func onlyTheLastMebibyteOfOutputIsKept() async throws {
        let filler = String(repeating: "x", count: 64)
        let result = try await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", """
                i=0
                while [ $i -lt 30000 ]; do
                  echo "line $i \(filler)"
                  i=$((i + 1))
                done
                echo "the end"
                """],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 60)
        #expect(result.status == 0)
        #expect(result.output.utf8.count <= FoundationProcessRunner.maximumOutputBytes)
        #expect(result.output.hasSuffix("line 29999 \(filler)\nthe end\n"))
        #expect(!result.output.contains("line 0 "))
    }
}
