import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

@Suite struct ResearchLocalModelsTests {
    private func makeRoot() throws -> URL {
        let root = temporaryDirectory("SandSeekModels")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A file of `size` bytes at `path` below `root`; the folders are made.
    @discardableResult
    private func write(_ relative: String, in root: URL, size: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
        return url
    }

    private func names(_ files: [ResearchLocalGGUF]) -> [String] { files.map(\.name) }

    // MARK: - llama.cpp

    @Test func aGGUFInANestedFolderIsFoundWithItsSize() throws {
        let root = try makeRoot()
        let file = try write("models/org/repo/Tiny-Q4.gguf", in: root, size: 1234)
        try write("models/org/repo/readme.txt", in: root)
        let found = ResearchLocalModels.findGGUF(roots: [root.path])
        #expect(names(found) == ["Tiny-Q4"])
        #expect(found.first?.size == 1234)
        #expect(found.first?.path == file.path)
    }

    @Test func visionProjectorsAreLeftOut() throws {
        let root = try makeRoot()
        try write("Gemma-Q4.gguf", in: root)
        try write("mmproj-Gemma-F16.gguf", in: root)
        try write("Gemma-MMPROJ-BF16.gguf", in: root)
        #expect(names(ResearchLocalModels.findGGUF(roots: [root.path])) == ["Gemma-Q4"])
    }

    @Test func onlyTheFirstPartOfASplitModelIsKept() throws {
        let root = try makeRoot()
        try write("Big-00001-of-00003.gguf", in: root)
        try write("Big-00002-of-00003.gguf", in: root)
        try write("Big-00003-of-00003.gguf", in: root)
        #expect(names(ResearchLocalModels.findGGUF(roots: [root.path])) == ["Big-00001-of-00003"])
    }

    @Test func hiddenSubfoldersAreSkippedButAHiddenRootIsSearched() throws {
        let base = try makeRoot()
        let hiddenRoot = base.appendingPathComponent(".cache", isDirectory: true)
        try write("visible/A.gguf", in: hiddenRoot)
        try write(".trash/B.gguf", in: hiddenRoot)
        #expect(names(ResearchLocalModels.findGGUF(roots: [hiddenRoot.path])) == ["A"])
    }

    @Test func aLinkToAFileIsFollowedAndShowsTheTargetSize() throws {
        let root = try makeRoot()
        let blob = try write("blobs/abc123", in: root, size: 5000)
        let snapshot = root.appendingPathComponent("snapshots/main", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let link = snapshot.appendingPathComponent("Linked-Q8.gguf")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: blob.path)
        let found = ResearchLocalModels.findGGUF(roots: [root.path])
        #expect(names(found) == ["Linked-Q8"])
        #expect(found.first?.size == 5000)
        #expect(found.first?.path == link.path)
    }

    @Test func aLinkToAFolderIsNotFollowed() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        try write("Outside.gguf", in: outside)
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: inside.appendingPathComponent("linked-folder").path,
            withDestinationPath: outside.path)
        #expect(ResearchLocalModels.findGGUF(roots: [root.path]).isEmpty)
    }

    @Test func theSameFileThroughTwoPathsIsListedOnce() throws {
        let root = try makeRoot()
        let model = try write("Same.gguf", in: root)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Same-link.gguf").path,
            withDestinationPath: model.path)
        #expect(ResearchLocalModels.findGGUF(roots: [root.path, root.path]).count == 1)
    }

    @Test func theSearchStopsSixLevelsBelowTheRoot() throws {
        let root = try makeRoot()
        try write("a/b/c/d/e/Deep6.gguf", in: root)
        try write("a/b/c/d/e/f/Deep7.gguf", in: root)
        #expect(names(ResearchLocalModels.findGGUF(roots: [root.path])) == ["Deep6"])
    }

    @Test func theFilesAreSortedByName() throws {
        let root = try makeRoot()
        try write("zeta.gguf", in: root)
        try write("Alpha.gguf", in: root)
        try write("mid/beta.gguf", in: root)
        #expect(names(ResearchLocalModels.findGGUF(roots: [root.path])) == ["Alpha", "beta", "zeta"])
    }

    @Test func emptyAndMissingRootsFindNothing() throws {
        let empty = try makeRoot()
        let missing = temporaryDirectory("SandSeekMissing").path
        #expect(ResearchLocalModels.findGGUF(roots: []).isEmpty)
        #expect(ResearchLocalModels.findGGUF(roots: [empty.path, missing]).isEmpty)
        #expect(ResearchLocalModels.findTUFFModels(folders: [empty.path, missing]).isEmpty)
    }

    @Test func theDefaultRootsComeFromTheHomeAndTheChosenModel() {
        let roots = ResearchLocalModels.defaultGGUFRoots(
            home: "/Users/test", chosenModel: "/Volumes/Big/models/x.gguf")
        #expect(roots.contains("/Users/test/Library/Caches/llama.cpp"))
        #expect(roots.contains("/Users/test/.cache/huggingface/hub"))
        #expect(roots.last == "/Volumes/Big/models")
        #expect(ResearchLocalModels.defaultGGUFRoots(home: "/Users/test", chosenModel: nil).count == 5)
    }

    // MARK: - TUFF

    private func installModel(_ name: String, in root: URL, manifest: String?,
                              verified: Bool = true) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let manifest {
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }
        if verified {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("verified-install.json"))
        }
    }

    @Test func onlyCompleteTUFFInstallsAreListed() throws {
        let root = try makeRoot()
        try installModel("qwen-folder", in: root, manifest: #"{"modelID": "qwen3-8b"}"#)
        try installModel("half-done", in: root, manifest: #"{"modelID": "half"}"#, verified: false)
        let found = ResearchLocalModels.findTUFFModels(folders: [root.path])
        #expect(found == [ResearchTUFFModelsFolder(path: root.path, models: ["qwen3-8b"])])
    }

    @Test func aManifestWithoutAModelIDFallsBackToTheFolderName() throws {
        let root = try makeRoot()
        try installModel("plain-folder", in: root, manifest: #"{"other": 1}"#)
        try installModel("broken-folder", in: root, manifest: "not json")
        let found = ResearchLocalModels.findTUFFModels(folders: [root.path])
        #expect(found.first?.models == ["broken-folder", "plain-folder"])
    }

    @Test func aTUFFFolderWithoutModelsIsLeftOut() throws {
        let withModel = try makeRoot()
        let without = try makeRoot()
        try installModel("m", in: withModel, manifest: #"{"modelID": "m1"}"#)
        try installModel("incomplete", in: without, manifest: nil)
        let found = ResearchLocalModels.findTUFFModels(folders: [without.path, withModel.path])
        #expect(found.map(\.path) == [withModel.path])
    }

    @Test func theDefaultTUFFFoldersIncludeTheCloneScratchFolder() {
        let folders = ResearchLocalModels.defaultTUFFFolders(
            home: "/Users/test", program: "/Code/TUFF/.build/release/TUFFServer")
        #expect(folders == ["/Users/test/Library/Application Support/TUFF/Models",
                            "/Code/TUFF/scratch"])
        #expect(ResearchLocalModels.defaultTUFFFolders(home: "/Users/test", program: nil).count == 1)
    }
}
