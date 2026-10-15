import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SandSeekCore

/// A new folder for one test, made the way the launcher makes the sandbox
/// folder (mode 0700).
private func sandboxFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SandSeekSandboxFolder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder
}

/// Writes `text` to `name` in `folder` with `mode` (the launcher writes 0600).
@discardableResult
private func write(_ text: String, to name: String, in folder: URL, mode: Int = 0o600) throws -> URL {
    let file = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    return file
}

@Suite struct ResearchSandboxPortFileTests {
    @Test func theRecordedPortIsRead() throws {
        let folder = try sandboxFolder()
        try write("54321\n", to: "port", in: folder)
        #expect(try ResearchSandboxFiles.readPort(in: folder) == 54_321)
        try write("1024", to: "port", in: folder)
        #expect(try ResearchSandboxFiles.readPort(in: folder) == 1_024)
        try write("65535\n", to: "port", in: folder)
        #expect(try ResearchSandboxFiles.readPort(in: folder) == 65_535)
    }

    @Test func noFileMeansNothingWasStarted() throws {
        let folder = try sandboxFolder()
        #expect(try ResearchSandboxFiles.readPort(in: folder) == nil)
        let missingFolder = folder.appendingPathComponent("gone", isDirectory: true)
        #expect(try ResearchSandboxFiles.readPort(in: missingFolder) == nil)
    }

    @Test func onlyDigitsFrom1024To65535AreAPort() throws {
        let folder = try sandboxFolder()
        let bad = ["", "\n", "80", "1023", "65536", "99999", "123456", "12a45", " 54321", "54321 ",
                   "5432\n1", "54321\n\n", "54321\r\n", "+5432", "-5432", "0x1234", "5.4321",
                   "\u{0665}\u{0664}\u{0663}\u{0662}\u{0661}", "54321\u{0}"]
        for text in bad {
            try write(text, to: "port", in: folder)
            #expect(throws: ResearchSandboxFileError.self, "\(text.debugDescription) was accepted") {
                _ = try ResearchSandboxFiles.readPort(in: folder)
            }
        }
    }

    @Test func theFileMustBeMode0600() throws {
        let folder = try sandboxFolder()
        for mode in [0o644, 0o640, 0o604, 0o660, 0o666, 0o400, 0o700] {
            try write("54321\n", to: "port", in: folder, mode: mode)
            #expect(throws: ResearchSandboxFileError.self, "mode \(String(mode, radix: 8)) was accepted") {
                _ = try ResearchSandboxFiles.readPort(in: folder)
            }
        }
        try write("54321\n", to: "port", in: folder, mode: 0o600)
        #expect(try ResearchSandboxFiles.readPort(in: folder) == 54_321)
    }

    @Test func aSymbolicLinkAFolderOrALongFileIsRefused() throws {
        let folder = try sandboxFolder()
        let real = try write("54321\n", to: "real", in: folder)
        let link = folder.appendingPathComponent("port")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        do {
            _ = try ResearchSandboxFiles.readPort(in: folder)
            Issue.record("a symbolic link was followed")
        } catch let error as ResearchSandboxFileError {
            #expect(error.message.contains("symbolic link"))
        }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        do {
            _ = try ResearchSandboxFiles.readPort(in: folder)
            Issue.record("a folder was read")
        } catch let error as ResearchSandboxFileError {
            #expect(error.message.contains("not a regular file"))
        }
        try FileManager.default.removeItem(at: link)
        try write(String(repeating: "1", count: 65), to: "port", in: folder)
        #expect(throws: ResearchSandboxFileError.self) { _ = try ResearchSandboxFiles.readPort(in: folder) }
    }

    @Test func theFileIsOwnedByTheCurrentUserLikeTheSecret() throws {
        // A file made by this test is ours; the check compares with the
        // effective user and does not look at the name of the user.
        let folder = try sandboxFolder()
        let file = try write("54321\n", to: "port", in: folder)
        var info = stat()
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_uid == geteuid())
        #expect(try ResearchSandboxFiles.readPort(in: folder) == 54_321)
    }
}

@Suite struct ResearchSandboxNameFileTests {
    @Test func aNameIsThePrefixAndEightHexDigits() {
        #expect(ResearchSandboxFiles.parseName("sandseek-sandbox-0123abcd") == "sandseek-sandbox-0123abcd")
        #expect(ResearchSandboxFiles.parseName("sandseek-sandbox-0123abcd\n") == "sandseek-sandbox-0123abcd")
        for bad in ["", "sandseek-sandbox", "sandseek-sandbox-", "sandseek-sandbox-0123abc",
                    "sandseek-sandbox-0123abcde", "sandseek-sandbox-0123ABCD", "sandseek-sandbox-0123abcg",
                    "other-0123abcd", " sandseek-sandbox-0123abcd", "sandseek-sandbox-0123abcd ",
                    "sandseek-sandbox-0123abcd\n\n", "sandseek-sandbox-debug1"] {
            #expect(ResearchSandboxFiles.parseName(bad) == nil, "\(bad.debugDescription) was accepted")
        }
    }

    @Test func theRecordedNameIsReadUnderTheSameRules() throws {
        let folder = try sandboxFolder()
        #expect(try ResearchSandboxFiles.readName(in: folder) == nil)
        try write("sandseek-sandbox-0123abcd\n", to: "vm-name", in: folder)
        #expect(try ResearchSandboxFiles.readName(in: folder) == "sandseek-sandbox-0123abcd")
        try write("sandseek-sandbox-0123abcd\n", to: "vm-name", in: folder, mode: 0o644)
        #expect(throws: ResearchSandboxFileError.self) { _ = try ResearchSandboxFiles.readName(in: folder) }
        try write("not a name\n", to: "vm-name", in: folder)
        #expect(throws: ResearchSandboxFileError.self) { _ = try ResearchSandboxFiles.readName(in: folder) }
    }
}

@Suite struct ResearchSandboxURLTests {
    @Test func theSandboxIsOnTheRecordedPort() throws {
        let folder = try sandboxFolder()
        try write("49152\n", to: "port", in: folder)
        #expect(ResearchSandboxFiles.sandboxURL(folder: folder, environment: [:]).absoluteString
            == "http://127.0.0.1:49152")
    }

    @Test func theEnvironmentOverridesTheRecordedPortForTests() throws {
        let folder = try sandboxFolder()
        try write("49152\n", to: "port", in: folder)
        let url = ResearchSandboxFiles.sandboxURL(
            folder: folder, environment: ["SANDSEEK_SANDBOX_PORT": "9555"])
        #expect(url.absoluteString == "http://127.0.0.1:9555")
        for bad in ["", "abc", "0", "80", "1023", "70000", "95 55"] {
            #expect(ResearchSandboxFiles.sandboxURL(
                folder: folder, environment: ["SANDSEEK_SANDBOX_PORT": bad]).absoluteString
                == "http://127.0.0.1:49152", "\(bad)")
        }
    }

    @Test func withoutAUsableRecordItIsPort9100() throws {
        let folder = try sandboxFolder()
        #expect(ResearchSandboxFiles.sandboxURL(folder: folder, environment: [:]).absoluteString
            == "http://127.0.0.1:9100")
        try write("80\n", to: "port", in: folder)
        #expect(ResearchSandboxFiles.sandboxURL(folder: folder, environment: [:]).absoluteString
            == "http://127.0.0.1:9100")
    }

    @Test func theCommandFindsTheSandboxLikeTheApp() throws {
        let folder = try sandboxFolder()
        try write("49152\n", to: "port", in: folder)
        var arguments = try ResearchArguments.parse(["question"])
        #expect(arguments.resolvedSandboxURL(folder: folder, environment: [:]).port == 49_152)
        arguments = try ResearchArguments.parse(["question", "--sandbox", "http://127.0.0.1:9333"])
        #expect(arguments.resolvedSandboxURL(folder: folder, environment: [:]).port == 9_333)
    }
}

@Suite struct ResearchSandboxLockTests {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aMissingOrEmptyLockFileIsFree() throws {
        let folder = try sandboxFolder()
        let file = ResearchSandboxFiles.lockFile(in: folder)
        #expect(ResearchSandboxLock.status(of: file) == .free)
        try write("", to: "lock", in: folder)
        #expect(ResearchSandboxLock.status(of: file) == .free)
    }

    @Test func aLockHeldByALiveProcessIsHeldAndNamesIt() throws {
        let folder = try sandboxFolder()
        let file = ResearchSandboxFiles.lockFile(in: folder)
        let lock = try #require(ResearchSandboxLock.acquire(at: file, now: when))
        // The lock is held until the end of the test.
        defer { withExtendedLifetime(lock) {} }
        #expect(ResearchSandboxLock.status(of: file) == .held(pid: getpid(), since: when))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content == "\(getpid()) 1700000000\n")
        // A second owner is refused, and the first is not disturbed.
        #expect(ResearchSandboxLock.acquire(at: file) == nil)
        #expect(ResearchSandboxLock.status(of: file) == .held(pid: getpid(), since: when))
        #expect(ResearchSandboxLock.busyMessage
            == "Another SandSeek is using the web sandbox. Close it first, or press Stop in it.")
    }

    @Test func probingUsesASharedLockSoProbesAndHoldersKeepTheirRoles() throws {
        let folder = try sandboxFolder()
        let file = ResearchSandboxFiles.lockFile(in: folder)
        try write("", to: "lock", in: folder)
        // While other readers hold a shared lock (probes of other copies of
        // the app), a probe still finds the lock free instead of "held".
        let first = open(file.path, O_RDONLY)
        let second = open(file.path, O_RDONLY)
        defer { close(first); close(second) }
        #expect(flock(first, LOCK_SH | LOCK_NB) == 0)
        #expect(flock(second, LOCK_SH | LOCK_NB) == 0)
        #expect(ResearchSandboxLock.status(of: file) == .free)
        // But a shared lock still keeps the exclusive holder out for that instant.
        #expect(ResearchSandboxLock.acquire(at: file) == nil)
        flock(first, LOCK_UN)
        flock(second, LOCK_UN)
        // The holder's exclusive lock excludes shared and exclusive takers, and
        // a probe sees it.
        let lock = try #require(ResearchSandboxLock.acquire(at: file, now: when))
        withExtendedLifetime(lock) {
            #expect(flock(first, LOCK_SH | LOCK_NB) != 0)
            #expect(flock(first, LOCK_EX | LOCK_NB) != 0)
            #expect(ResearchSandboxLock.status(of: file) == .held(pid: getpid(), since: when))
        }
    }

    @Test func releasingLetsTheNextOwnerIn() throws {
        let folder = try sandboxFolder()
        let file = ResearchSandboxFiles.lockFile(in: folder)
        let first = try #require(ResearchSandboxLock.acquire(at: file, now: when))
        first.release()
        first.release()
        let second = try #require(ResearchSandboxLock.acquire(at: file, now: when))
        withExtendedLifetime(second) {
            #expect(ResearchSandboxLock.status(of: file) == .held(pid: getpid(), since: when))
        }
    }

    @Test func aLockWhoseProcessIsGoneIsStaleAndIsTakenOver() throws {
        let folder = try sandboxFolder()
        let file = ResearchSandboxFiles.lockFile(in: folder)
        // A process that has ended, so its number is no live owner's.
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let gone = finished.processIdentifier
        try write("\(gone) 1700000000\n", to: "lock", in: folder)
        #expect(ResearchSandboxLock.status(of: file) == .stale(pid: gone))
        let lock = try #require(ResearchSandboxLock.acquire(at: file, now: when))
        withExtendedLifetime(lock) {
            #expect(ResearchSandboxLock.status(of: file) == .held(pid: getpid(), since: when))
        }
    }

    @Test func theOwnerIsReadStrictly() {
        let owner = ResearchSandboxLock.parseOwner("1234 1700000000\n")
        #expect(owner.pid == 1_234)
        #expect(owner.since == when)
        #expect(ResearchSandboxLock.parseOwner("1234").since == nil)
        for bad in ["", "\n", "abc 1", "-5 1", "0 1", "12x4 1", "99999999999 1"] {
            #expect(ResearchSandboxLock.parseOwner(bad).pid == nil, "\(bad.debugDescription)")
        }
    }
}
