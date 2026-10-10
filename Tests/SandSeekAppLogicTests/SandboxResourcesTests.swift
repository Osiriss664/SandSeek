import Foundation
import Testing
@testable import SandSeekAppLogic

@Suite struct SandboxResourcesTests {
    private func resources(bundle: URL?, environment: [String: String] = [:],
                           allowsOverride: Bool = false) -> SandboxResources {
        SandboxResources(bundledRoot: bundle, environment: environment, allowsOverride: allowsOverride)
    }

    @Test func theAppsFilesAreUsedInPlaceAndNothingIsCopied() throws {
        let bundle = try fakeSandboxBundle()
        let files = try resources(bundle: bundle).prepare()
        #expect(files.origin == .bundled)
        #expect(files.root.standardizedFileURL.path == bundle.standardizedFileURL.path)
        #expect(files.script.path.hasSuffix("Scripts/research_sandbox.sh"))
        #expect(files.sandboxFolder.lastPathComponent == "Sandbox")
        // The script finds its build context at ../Sandbox.
        #expect(FileManager.default.fileExists(
            atPath: files.script.deletingLastPathComponent()
                .appendingPathComponent("../Sandbox/Containerfile").path))
        // No Application Support copy is made or looked at.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        #expect(support.map { !files.root.path.hasPrefix($0.path) } ?? true)
    }

    @Test func withoutFilesInTheAppItSaysSo() {
        let none = resources(bundle: nil)
        #expect(throws: SandboxResourcesError.noBundledFiles) { _ = try none.prepare() }
        let empty = resources(bundle: temporaryDirectory("Empty"))
        #expect(throws: SandboxResourcesError.noBundledFiles) { _ = try empty.prepare() }
        #expect(SandboxResourcesError.noBundledFiles.description.contains("Scripts/package_app.sh"))
    }

    @Test func aDeveloperCheckoutIsUsedInPlaceWhereTheOverrideIsAllowed() throws {
        let checkout = try fakeSandboxBundle()
        let bundle = try fakeSandboxBundle()
        let files = try resources(
            bundle: bundle, environment: [SandboxResources.overrideVariable: checkout.path],
            allowsOverride: true).prepare()
        #expect(files.origin == .checkout)
        #expect(files.root.standardizedFileURL.path == checkout.standardizedFileURL.path)
        #expect(SandboxResources.overrideVariable == "SANDSEEK_SOURCE_DIR")
    }

    @Test func aReleaseBuildIgnoresTheOverrideWhenItHasItsOwnFiles() throws {
        let checkout = try fakeSandboxBundle()
        let bundle = try fakeSandboxBundle()
        let files = try resources(
            bundle: bundle, environment: [SandboxResources.overrideVariable: checkout.path],
            allowsOverride: false).prepare()
        #expect(files.origin == .bundled)
        #expect(files.root.standardizedFileURL.path == bundle.standardizedFileURL.path)
        // A wrong value is ignored as well, instead of failing the sandbox.
        let wrong = try resources(
            bundle: bundle, environment: [SandboxResources.overrideVariable: "/nonexistent"],
            allowsOverride: false).prepare()
        #expect(wrong.origin == .bundled)
    }

    @Test func withoutFilesInTheAppTheOverrideWorksEvenInAReleaseBuild() throws {
        // `swift run`: a bare executable has no sandbox files of its own.
        let checkout = try fakeSandboxBundle()
        let files = try resources(
            bundle: nil, environment: [SandboxResources.overrideVariable: checkout.path],
            allowsOverride: false).prepare()
        #expect(files.origin == .checkout)
    }

    @Test func aWrongCheckoutIsRefusedAndAnEmptyValueIsIgnored() throws {
        let bundle = try fakeSandboxBundle()
        let wrong = temporaryDirectory("NotACheckout")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        let refused = resources(
            bundle: bundle, environment: [SandboxResources.overrideVariable: wrong.path],
            allowsOverride: true)
        #expect(throws: SandboxResourcesError.notACheckout(wrong.standardizedFileURL.path)) {
            _ = try refused.prepare()
        }
        // Not a quiet fall back to the app's files: the developer asked for another folder.
        let blank = resources(
            bundle: bundle, environment: [SandboxResources.overrideVariable: ""],
            allowsOverride: true)
        #expect(try blank.prepare().origin == .bundled)
    }

    @Test func theDefaultAllowsTheOverrideInDebugBuildsOnly() {
        #if DEBUG
        #expect(SandboxResources.overrideAllowedByDefault)
        #else
        #expect(!SandboxResources.overrideAllowedByDefault)
        #endif
    }

    @Test func theBundledFolderIsNamedLikeThePackagingScriptMakesIt() {
        let root = SandboxResources.defaultBundledRoot(bundle: Bundle(for: Marker.self))
        #expect(root?.lastPathComponent == "sandbox")
    }

    private final class Marker {}
}
