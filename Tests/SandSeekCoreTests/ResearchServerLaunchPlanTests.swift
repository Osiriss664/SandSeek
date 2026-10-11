import Foundation
import Testing
@testable import SandSeekCore

@Suite struct ResearchServerLaunchPlanTests {
    @Test func tuffGetsThePortAndOnlyAChosenModelsFolder() throws {
        let plain = try ResearchServerLaunchPlan.tuff(
            server: "/Apps/TUFF.app/Contents/Resources/bin/TUFFServer", modelsRoot: nil, port: 8080)
        #expect(plain.executable == "/Apps/TUFF.app/Contents/Resources/bin/TUFFServer")
        #expect(plain.arguments == ["--port", "8080"])
        let withFolder = try ResearchServerLaunchPlan.tuff(
            server: "/x/TUFFServer", modelsRoot: "/Users/me/My Models", port: 9090)
        #expect(withFolder.arguments == ["--port", "9090", "--models-root", "/Users/me/My Models"])
        // TUFFServer has no host option; none is passed.
        #expect(!withFolder.arguments.contains("--host"))
    }

    @Test func llamaCppGetsTheFixedArgumentList() throws {
        let plan = try ResearchServerLaunchPlan.llamacpp(
            server: "/opt/homebrew/Cellar/llama.cpp/1/bin/llama-server",
            model: "/Users/me/Models/Qwen3-Q4_K_M.gguf", port: 8081,
            keyFile: "/Users/me/Library/Application Support/SandSeek/State/llamacpp-api-key")
        #expect(plan.arguments == [
            "-m", "/Users/me/Models/Qwen3-Q4_K_M.gguf", "--alias", "Qwen3-Q4_K_M",
            "--host", "127.0.0.1", "--port", "8081", "-c", "16384", "-np", "1", "--jinja",
            "--api-key-file", "/Users/me/Library/Application Support/SandSeek/State/llamacpp-api-key",
        ])
        // No key value, no verbose logging, no option from outside.
        #expect(!plan.arguments.contains("--api-key"))
        #expect(!plan.arguments.contains("-v") && !plan.arguments.contains("--verbose"))
    }

    @Test func theAliasIsASafeShortName() {
        let alias = ResearchServerLaunchPlan.alias(fromModelFile:)
        #expect(alias("/m/gemma-4-e4b-it.Q4_K_M.gguf") == "gemma-4-e4b-it.Q4_K_M")
        #expect(alias("/m/Model.GGUF") == "Model")
        // Characters outside letters, digits and . _ - are dropped; a name never
        // begins with "-", which could be read as an option.
        #expect(alias("/m/--evil model!.gguf") == "evilmodel")
        #expect(alias("/m/-x.gguf") == "x")
        #expect(alias("/m/ä ö.gguf") == "model")
        #expect(alias("/m/" + String(repeating: "a", count: 100) + ".gguf").count == 64)
    }

    @Test func pathsMustBeAbsoluteAndPlain() {
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.tuff(server: "TUFFServer", modelsRoot: nil, port: 8080)
        }
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.tuff(server: "-x/TUFFServer", modelsRoot: nil, port: 8080)
        }
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.tuff(server: "/x/TUFFServer", modelsRoot: "models", port: 8080)
        }
        for bad in ["/x/a\nb", "/x/a\tb", "/x/a\u{1B}[2Jb", "/x/a\u{0}b", "/x/a\u{2028}b", ""] {
            #expect(throws: ResearchLaunchProblem.self) {
                _ = try ResearchServerLaunchPlan.llamacpp(
                    server: bad, model: "/m/a.gguf", port: 8081, keyFile: "/k")
            }
            #expect(throws: ResearchLaunchProblem.self) {
                _ = try ResearchServerLaunchPlan.llamacpp(
                    server: "/x/llama-server", model: bad, port: 8081, keyFile: "/k")
            }
            #expect(throws: ResearchLaunchProblem.self) {
                _ = try ResearchServerLaunchPlan.llamacpp(
                    server: "/x/llama-server", model: "/m/a.gguf", port: 8081, keyFile: bad)
            }
        }
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.llamacpp(
                server: "/x/llama-server", model: "/m/a.bin", port: 8081, keyFile: "/k")
        }
    }

    @Test func portsBelow1024AndAbove65535AreRefused() {
        for port in [0, 80, 1_023, 65_536] {
            #expect(throws: ResearchLaunchProblem.self) {
                _ = try ResearchServerLaunchPlan.tuff(server: "/x/TUFFServer", modelsRoot: nil, port: port)
            }
        }
        #expect((try? ResearchServerLaunchPlan.tuff(
            server: "/x/TUFFServer", modelsRoot: nil, port: 1_024)) != nil)
    }

    @Test func theEnvironmentHoldsOnlyThreeVariablesMadeHere() {
        #expect(ResearchServerLaunchPlan.environment(home: "/Users/me", tmp: "/tmp/t/") == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me", "TMPDIR": "/tmp/t/",
        ])
        // What the app's own environment holds does not matter.
        setenv("LLAMA_ARG_API_KEY", "leak", 1)
        setenv("DYLD_INSERT_LIBRARIES", "/evil.dylib", 1)
        setenv("TUFF_KERNEL", "x", 1)
        defer {
            unsetenv("LLAMA_ARG_API_KEY")
            unsetenv("DYLD_INSERT_LIBRARIES")
            unsetenv("TUFF_KERNEL")
        }
        let plan = try? ResearchServerLaunchPlan.llamacpp(
            server: "/x/llama-server", model: "/m/a.gguf", port: 8081, keyFile: "/k")
        #expect(Set((plan?.environment ?? [:]).keys) == ["PATH", "HOME", "TMPDIR"])
    }

    @Test func aTuffPickBecomesTheTUFFServerBesideIt() throws {
        let exists: (String) -> Bool = { _ in true }
        func server(_ pick: String) throws -> String {
            try ResearchServerLaunchPlan.tuffServerPath(forPick: pick, fileExists: exists)
        }
        #expect(try server("/Applications/TUFF.app")
            == "/Applications/TUFF.app/Contents/Resources/bin/TUFFServer")
        #expect(try server("/Applications/TUFF.app/")
            == "/Applications/TUFF.app/Contents/Resources/bin/TUFFServer")
        #expect(try server("/Apps/TUFF.app/Contents/Resources/bin/tuff")
            == "/Apps/TUFF.app/Contents/Resources/bin/TUFFServer")
        #expect(try server("/src/tuff/.build/release/tuff") == "/src/tuff/.build/release/TUFFServer")
        #expect(try server("/src/tuff/.build/release/TUFFServer")
            == "/src/tuff/.build/release/TUFFServer")
        // Any other program, a relative path, or a missing TUFFServer is refused.
        for bad in ["/usr/bin/true", "/x/TUFFServer.sh", "tuff", "/x/tuff-server"] {
            #expect(throws: ResearchLaunchProblem.self) { _ = try server(bad) }
        }
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.tuffServerPath(
                forPick: "/x/tuff", fileExists: { _ in false })
        }
    }

    @Test func aCloneBuildHintsAtItsScratchFolder() {
        #expect(ResearchServerLaunchPlan.cloneModelsHint(
            forProgram: "/Users/me/Developer/TUFF/.build/release/TUFFServer")
            == "/Users/me/Developer/TUFF/scratch")
        #expect(ResearchServerLaunchPlan.cloneModelsHint(
            forProgram: "/Applications/TUFF.app/Contents/Resources/bin/TUFFServer") == nil)
    }

    @Test func llamaCppMustBeCalledLlamaServer() throws {
        #expect(try ResearchServerLaunchPlan.llamaServerPath(forPick: "/opt/homebrew/bin/llama-server")
            == "/opt/homebrew/bin/llama-server")
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.llamaServerPath(forPick: "/bin/sh")
        }
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLaunchPlan.llamaServerPath(forPick: "llama-server")
        }
    }
}

@Suite struct ResearchExecutableCheckTests {
    private let me: UInt32 = 501

    private func file(uid: UInt32 = 501, gid: UInt32 = 20, mode: UInt32 = 0o755,
                      kind: ResearchFileFacts.Kind = .regular, quarantined: Bool = false,
                      executable: Bool = true) -> ResearchFileFacts {
        ResearchFileFacts(path: "/Apps/server", kind: kind, uid: uid, gid: gid, mode: mode,
                          isExecutable: executable, isQuarantined: quarantined)
    }

    private func folder(_ path: String, uid: UInt32 = 0, gid: UInt32 = 0,
                        mode: UInt32 = 0o755) -> ResearchFileFacts {
        ResearchFileFacts(path: path, kind: .directory, uid: uid, gid: gid, mode: mode)
    }

    private func problem(file: ResearchFileFacts, ancestors: [ResearchFileFacts] = []) -> String? {
        ResearchExecutableCheck.evaluate(file: file, ancestors: ancestors, uid: me)?.message
    }

    @Test func anOrdinaryProgramPasses() {
        #expect(problem(file: file(), ancestors: [folder("/"), folder("/opt"),
                                                  folder("/opt/homebrew", uid: 501, gid: 20)]) == nil)
        #expect(problem(file: file(uid: 0, gid: 0)) == nil)
    }

    @Test func theFileItselfMustBeRegularMineOrRootsAndNotWritableByOthers() {
        #expect(problem(file: file(mode: 0o775))?.contains("can be changed by other users") == true)
        #expect(problem(file: file(mode: 0o757))?.contains("can be changed by other users") == true)
        #expect(problem(file: file(uid: 502))?.contains("another user") == true)
        #expect(problem(file: file(kind: .symlink))?.contains("not a regular") == true)
        #expect(problem(file: file(kind: .directory))?.contains("not a regular") == true)
        #expect(problem(file: file(executable: false))?.contains("cannot be run") == true)
    }

    @Test func everyFolderAboveItIsChecked() {
        let tmp = folder("/tmp", mode: 0o1777)
        let writable = folder("/opt/shared", uid: 501, mode: 0o777)
        // Anyone can rename the program in a world-writable folder ...
        #expect(problem(file: file(), ancestors: [folder("/"), writable])?
            .contains("/opt/shared") == true)
        // ... unless the sticky bit stops them, as in /tmp.
        #expect(problem(file: file(), ancestors: [folder("/"), tmp]) == nil)
        // A folder of another user, or a link in the chain, is refused.
        #expect(problem(file: file(), ancestors: [folder("/"), folder("/Users/x", uid: 502)])?
            .contains("belongs to another user") == true)
        var link = folder("/opt/link")
        link.kind = .symlink
        #expect(problem(file: file(), ancestors: [folder("/"), link])?.contains("not a folder") == true)
        // A folder far up the chain counts too.
        #expect(problem(file: file(), ancestors: [folder("/", mode: 0o777), folder("/opt")]) != nil)
    }

    @Test func rootsAdminGroupMayWriteButNoOtherGroup() {
        // /Applications is root:admin 775 on every Mac.
        let applications = folder("/Applications", uid: 0, gid: 80, mode: 0o775)
        #expect(problem(file: file(uid: 0, gid: 80), ancestors: [folder("/"), applications]) == nil)
        // The same mode for another group, or in a folder of mine, is refused.
        #expect(problem(file: file(), ancestors: [folder("/"),
            folder("/Applications", uid: 0, gid: 20, mode: 0o775)]) != nil)
        #expect(problem(file: file(), ancestors: [folder("/"),
            folder("/Users/me/bin", uid: 501, gid: 80, mode: 0o775)]) != nil)
    }

    @Test func aDownloadedFileIsRefusedWithTheWayOut() {
        let text = problem(file: file(quarantined: true))
        #expect(text?.contains("downloaded") == true)
        #expect(text?.contains("Terminal") == true)
    }

    // MARK: - Real files

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekExecutable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        return folder
    }

    @Test func aRealProgramIsResolvedAndChecked() throws {
        let folder = try temporaryFolder()
        let program = folder.appendingPathComponent("llama-server")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let uid = UInt32(getuid())

        let resolved = try ResearchExecutableCheck.resolveAndCheck(program.path, uid: uid).get()
        #expect(resolved.hasSuffix("/llama-server"))

        // A link is followed, and the target is what is checked and started.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: program.path)
        #expect(try ResearchExecutableCheck.resolveAndCheck(link.path, uid: uid).get() == resolved)

        // Writable by the group: refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: program.path)
        if case .success = ResearchExecutableCheck.resolveAndCheck(program.path, uid: uid) {
            Issue.record("a group-writable program was accepted")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        // In a folder that others can write to: refused.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
        if case .success = ResearchExecutableCheck.resolveAndCheck(program.path, uid: uid) {
            Issue.record("a program in a world-writable folder was accepted")
        }
        // Not there at all.
        if case .success = ResearchExecutableCheck.resolveAndCheck(folder.path + "/nope", uid: uid) {
            Issue.record("a missing program was accepted")
        }
    }

    @Test func theKeyFileMustBeMineMode0600AndHoldTheKey() throws {
        let folder = try temporaryFolder()
        let uid = UInt32(getuid())
        func make(_ name: String, _ text: String, mode: Int = 0o600) throws -> String {
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url.path
        }
        func problem(_ path: String?) -> String? {
            ResearchExecutableCheck.keyFileProblem(path: path, key: "abc123", uid: uid)?.message
        }
        #expect(problem(try make("good", "abc123\n")) == nil)
        #expect(problem(try make("open", "abc123", mode: 0o644))?.contains("0600") == true)
        #expect(problem(try make("other", "zzz999"))?.contains("does not hold") == true)
        #expect(problem(nil)?.contains("no key file") == true)
        #expect(problem(folder.path + "/missing")?.contains("not a regular file") == true)
        // A link to a good file is not a regular file.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: folder.path + "/good")
        #expect(problem(link.path)?.contains("not a regular file") == true)
        // The key never appears in the message.
        #expect(problem(try make("other2", "zzz999"))?.contains("abc123") == false)
    }
}

@Suite struct ResearchServerFilesTests {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekServerFiles-\(UUID().uuidString)", isDirectory: true)
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0)
            & 0o777
    }

    @Test func theLogIsFreshPrivateAndNeverFollowsALink() throws {
        let folder = temporaryFolder().appendingPathComponent("Logs")
        let log = folder.appendingPathComponent("model-server.log")
        let first = try ResearchServerLog.create(at: log)
        first.write(Data("old\n".utf8))
        try first.close()
        #expect(try mode(folder) == 0o700)
        #expect(try mode(log) == 0o600)

        // The next start replaces the file.
        let second = try ResearchServerLog.create(at: log)
        try second.close()
        #expect(try Data(contentsOf: log).isEmpty)

        // A link planted at the log's place is removed, not written through.
        let target = temporaryFolder().appendingPathComponent("victim")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(atPath: log.path, withDestinationPath: target.path)
        let third = try ResearchServerLog.create(at: log)
        third.write(Data("new".utf8))
        try third.close()
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(try String(contentsOf: log, encoding: .utf8) == "new")
        #expect(try mode(log) == 0o600)

        // A folder that is a link is refused.
        let linked = temporaryFolder()
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: folder.path)
        #expect(throws: ResearchLaunchProblem.self) {
            _ = try ResearchServerLog.create(at: linked.appendingPathComponent("model-server.log"))
        }
    }

    @Test func theTailIsTheLastLinesCleanedAndWithoutKeyLines() throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("log")
        var text = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        text += "main: api_keys: ****cdef\n"
        text += "bind: \u{1B}[31maddress already in use\u{1B}[0m\u{202E}\n"
        try Data(text.utf8).write(to: log)
        let tail = ResearchServerLog.tail(at: log)
        let lines = tail.split(separator: "\n").map(String.init)
        #expect(lines.count == 6)
        #expect(lines.last == "bind: [31maddress already in use[0m")
        #expect(!tail.contains("\u{1B}"))
        #expect(!tail.contains("\u{202E}"))
        #expect(!tail.contains("api_keys"))
        #expect(lines.first == "line 16")
        #expect(ResearchServerLog.tail(at: folder.appendingPathComponent("missing")) == "")
    }

    @Test func onlyTheEndOfABigLogIsRead() throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("log")
        let filler = String(repeating: "x", count: 100) + "\n"
        let text = String(repeating: filler, count: 2_000) + "the end\n"
        try Data(text.utf8).write(to: log)
        let tail = ResearchServerLog.tail(at: log, lines: 2, bytes: 1_000)
        #expect(tail.hasSuffix("the end"))
        #expect(tail.split(separator: "\n").count == 2)
    }

    @Test func theMarkerIsPrivateAndRoundTrips() throws {
        let folder = temporaryFolder().appendingPathComponent("State")
        let identity = ResearchProcessIdentity(
            startSeconds: 1_700_000_000, startMicroseconds: 42, path: "/opt/TUFFServer")
        let marker = ResearchServerMarker(type: "tuff", port: 8080, pid: 4_242, identity: identity)
        try marker.write(to: folder)
        let file = folder.appendingPathComponent(ResearchServerMarker.fileName)
        #expect(try mode(file) == 0o600)
        #expect(try mode(folder) == 0o700)
        #expect(ResearchServerMarker.load(from: folder) == marker)
        #expect(ResearchServerMarker.load(from: folder)?.identity == identity)
        try Data("not json".utf8).write(to: file)
        #expect(ResearchServerMarker.load(from: folder) == nil)
        ResearchServerMarker.remove(from: folder)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
