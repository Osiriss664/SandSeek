import Foundation
import Testing
@testable import SandSeekAppLogic

@Suite struct SandboxResourcesTests {
    private func resources(bundle: URL, install: URL = temporaryDirectory("SandSeekInstall"),
                           environment: [String: String] = [:]) -> SandboxResources {
        SandboxResources(bundledRoot: bundle, installRoot: install, environment: environment)
    }

    @Test func firstUseCopiesTheFilesAndRunsFromTheCopy() throws {
        let bundle = try fakeSandboxBundle()
        let install = temporaryDirectory("SandSeekInstall")
        #expect(!FileManager.default.fileExists(atPath: install.path))

        let files = try resources(bundle: bundle, install: install).prepare()
        #expect(files.didCopy)
        #expect(files.origin == .installedCopy)
        #expect(files.root.standardizedFileURL.path == install.standardizedFileURL.path)
        #expect(files.script.path.hasSuffix("Scripts/research_sandbox.sh"))
        #expect(files.sandboxFolder.lastPathComponent == "Sandbox")
        for path in ["Scripts/research_sandbox.sh", "Sandbox/Containerfile", "Sandbox/server.py"] {
            #expect(FileManager.default.fileExists(atPath: install.appendingPathComponent(path).path))
        }
        #expect(SandboxResources.contentHash(of: install) == SandboxResources.contentHash(of: bundle))
        // The files in the app are left as they were.
        #expect(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Sandbox/server.py").path))
    }

    @Test func anUnchangedCopyIsNotCopiedAgain() throws {
        let bundle = try fakeSandboxBundle()
        let install = temporaryDirectory("SandSeekInstall")
        let sandbox = resources(bundle: bundle, install: install)
        #expect(try sandbox.prepare().didCopy)
        #expect(try sandbox.prepare().didCopy == false)
        #expect(try sandbox.prepare().didCopy == false)
    }

    @Test func aChangedHashInTheAppReplacesTheCopy() throws {
        let bundle = try fakeSandboxBundle()
        let install = temporaryDirectory("SandSeekInstall")
        let sandbox = resources(bundle: bundle, install: install)
        _ = try sandbox.prepare()
        let before = SandboxResources.contentHash(of: install)

        // A new app version: a changed server, a new file, a removed file.
        try Data("print('new')\n".utf8).write(to: bundle.appendingPathComponent("Sandbox/server.py"))
        try Data("nft\n".utf8).write(to: bundle.appendingPathComponent("Sandbox/firewall.nft"))
        let second = try sandbox.prepare()
        #expect(second.didCopy)
        #expect(SandboxResources.contentHash(of: install) != before)
        #expect(try String(contentsOf: install.appendingPathComponent("Sandbox/server.py"),
                           encoding: .utf8) == "print('new')\n")
        #expect(FileManager.default.fileExists(
            atPath: install.appendingPathComponent("Sandbox/firewall.nft").path))

        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Sandbox/firewall.nft"))
        #expect(try sandbox.prepare().didCopy)
        #expect(!FileManager.default.fileExists(
            atPath: install.appendingPathComponent("Sandbox/firewall.nft").path))
        #expect(try sandbox.prepare().didCopy == false)
    }

    @Test func aCopyThatWasAlteredIsReplaced() throws {
        let bundle = try fakeSandboxBundle()
        let install = temporaryDirectory("SandSeekInstall")
        let sandbox = resources(bundle: bundle, install: install)
        _ = try sandbox.prepare()

        let script = install.appendingPathComponent("Scripts/research_sandbox.sh")
        try Data("#!/bin/bash\necho tampered\n".utf8).write(to: script)
        #expect(try sandbox.prepare().didCopy)
        #expect(try String(contentsOf: script, encoding: .utf8) == "#!/bin/bash\n")

        // A file that does not belong there counts as well.
        try Data("x".utf8).write(to: install.appendingPathComponent("Sandbox/extra.py"))
        #expect(try sandbox.prepare().didCopy)
        #expect(!FileManager.default.fileExists(
            atPath: install.appendingPathComponent("Sandbox/extra.py").path))
    }

    @Test func aLinkInThePlaceOfTheScriptIsReplaced() throws {
        let bundle = try fakeSandboxBundle()
        let install = temporaryDirectory("SandSeekInstall")
        let sandbox = resources(bundle: bundle, install: install)
        _ = try sandbox.prepare()
        let script = install.appendingPathComponent("Scripts/research_sandbox.sh")
        let elsewhere = temporaryDirectory("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let other = elsewhere.appendingPathComponent("evil.sh")
        try Data("#!/bin/bash\n".utf8).write(to: other)
        try FileManager.default.removeItem(at: script)
        try FileManager.default.createSymbolicLink(at: script, withDestinationURL: other)

        #expect(try sandbox.prepare().didCopy)
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        let type = attributes[.type] as? FileAttributeType
        #expect(type == .typeRegular)
    }

    @Test func withoutFilesInTheAppItSaysSo() {
        let none = SandboxResources(
            bundledRoot: nil, installRoot: temporaryDirectory("SandSeekInstall"), environment: [:])
        #expect(throws: SandboxResourcesError.noBundledFiles) { _ = try none.prepare() }
        let empty = SandboxResources(
            bundledRoot: temporaryDirectory("Empty"),
            installRoot: temporaryDirectory("SandSeekInstall"), environment: [:])
        #expect(throws: SandboxResourcesError.noBundledFiles) { _ = try empty.prepare() }
        #expect(SandboxResourcesError.noBundledFiles.description.contains("Scripts/package_app.sh"))
    }

    @Test func aDeveloperCheckoutIsUsedInPlaceAndNothingIsCopied() throws {
        let checkout = try fakeSandboxBundle()
        let bundle = try fakeSandboxBundle()
        let install = temporaryDirectory("SandSeekInstall")
        let sandbox = resources(
            bundle: bundle, install: install,
            environment: [SandboxResources.overrideVariable: checkout.path])
        let files = try sandbox.prepare()
        #expect(files.origin == .checkout)
        #expect(!files.didCopy)
        #expect(files.root.standardizedFileURL.path == checkout.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: install.path))
        #expect(SandboxResources.overrideVariable == "SANDSEEK_SOURCE_DIR")
    }

    @Test func aWrongCheckoutIsRefusedAndAnEmptyValueIsIgnored() throws {
        let bundle = try fakeSandboxBundle()
        let wrong = temporaryDirectory("NotACheckout")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        let refused = resources(
            bundle: bundle, environment: [SandboxResources.overrideVariable: wrong.path])
        #expect(throws: SandboxResourcesError.notACheckout(wrong.standardizedFileURL.path)) {
            _ = try refused.prepare()
        }
        // Not a quiet fall back to the app's files: the developer asked for another folder.
        let blank = resources(bundle: bundle, environment: [SandboxResources.overrideVariable: ""])
        #expect(try blank.prepare().origin == .installedCopy)
    }

    @Test func theHashCountsTheScriptAndTheBuildContextOnly() throws {
        let bundle = try fakeSandboxBundle()
        let base = SandboxResources.contentHash(of: bundle)
        #expect(!base.isEmpty)
        #expect(base.count == 64)

        // Bytecode caches and Finder metadata do not count.
        let cache = bundle.appendingPathComponent("Sandbox/__pycache__", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appendingPathComponent("server.cpython-312.pyc"))
        try Data("x".utf8).write(to: bundle.appendingPathComponent("Sandbox/.DS_Store"))
        #expect(SandboxResources.contentHash(of: bundle) == base)
        // Files elsewhere in the folder do not count either.
        try Data("x".utf8).write(to: bundle.appendingPathComponent("notes.txt"))
        #expect(SandboxResources.contentHash(of: bundle) == base)

        // The script counts: it holds the VM's security options.
        try Data("#!/bin/bash\n# changed\n".utf8).write(
            to: bundle.appendingPathComponent("Scripts/research_sandbox.sh"))
        let afterScript = SandboxResources.contentHash(of: bundle)
        #expect(afterScript != base)
        // So does every file in the build context, and a file's name.
        try Data("FROM other\n".utf8).write(to: bundle.appendingPathComponent("Sandbox/Containerfile"))
        let afterContainerfile = SandboxResources.contentHash(of: bundle)
        #expect(afterContainerfile != afterScript)
        try FileManager.default.moveItem(
            at: bundle.appendingPathComponent("Sandbox/server.py"),
            to: bundle.appendingPathComponent("Sandbox/server2.py"))
        #expect(SandboxResources.contentHash(of: bundle) != afterContainerfile)
    }

    @Test func aFolderWithNothingToHashHasNoHash() {
        #expect(SandboxResources.contentHash(of: temporaryDirectory("Missing")) == "")
    }

    @Test func theInstallFolderIsInSandSeeksApplicationSupport() {
        let path = SandboxResources.defaultInstallRoot().path
        #expect(path.hasSuffix("Application Support/SandSeek/Sandbox"))
    }
}
