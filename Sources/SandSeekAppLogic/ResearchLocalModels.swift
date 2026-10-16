import Foundation
import SandSeekCore

/// A `.gguf` model file found on this Mac.
public struct ResearchLocalGGUF: Equatable, Sendable, Identifiable {
    /// The path as found. For a Hugging Face snapshot this is the link, not
    /// the blob it points to.
    public let path: String
    /// The file name without `.gguf`.
    public let name: String
    /// The size of the file itself (of the target, for a link).
    public let size: Int64

    public var id: String { path }

    public init(path: String, name: String, size: Int64) {
        self.path = path
        self.name = name
        self.size = size
    }
}

/// A TUFF models folder and the installed models in it.
public struct ResearchTUFFModelsFolder: Equatable, Sendable, Identifiable {
    public let path: String
    /// The `modelID` of each installed model (the folder name when the
    /// manifest has none), sorted.
    public let models: [String]

    public var id: String { path }

    public init(path: String, models: [String]) {
        self.path = path
        self.models = models
    }
}

/// Finds the models the model servers already keep on this Mac, so the card
/// can offer them instead of a file dialog. It only lists folders and reads
/// two small JSON files per TUFF model: it never writes, downloads or runs
/// anything. The folders are passed in, so the tests use temporary ones.
public enum ResearchLocalModels {
    /// How deep below a root a file may be, and how many entries one search
    /// looks at in all. Both keep a search through a big folder short.
    static let maxDepth = 6
    static let maxEntries = 5_000
    /// A manifest larger than this is not read.
    static let maxManifestBytes = 1_000_000

    // MARK: - Where to look

    /// The folders where llama.cpp, LM Studio and Hugging Face keep `.gguf`
    /// files, below `home`, and the folder of the model chosen last.
    public static func defaultGGUFRoots(home: String, chosenModel: String?) -> [String] {
        var roots = [
            "Library/Caches/llama.cpp", ".cache/llama.cpp", ".lmstudio/models",
            ".cache/lm-studio/models", ".cache/huggingface/hub",
        ].map { home + "/" + $0 }
        if let chosenModel, !chosenModel.isEmpty {
            roots.append((chosenModel as NSString).deletingLastPathComponent)
        }
        return roots
    }

    /// TUFF's own models folder below `home`, and the `scratch` folder of the
    /// clone the chosen TUFFServer was built in.
    public static func defaultTUFFFolders(home: String, program: String?) -> [String] {
        var folders = [home + "/Library/Application Support/TUFF/Models"]
        if let program, let hint = ResearchServerLaunchPlan.cloneModelsHint(forProgram: program) {
            folders.append(hint)
        }
        return folders
    }

    // MARK: - llama.cpp

    /// The `.gguf` files in `roots`, sorted by name, without the same file
    /// twice. Hidden folders below a root are skipped (a root itself may be
    /// hidden, such as `~/.cache`). A link to a file is followed, because a
    /// Hugging Face snapshot holds links to its blobs; a link to a folder is
    /// not. Vision projectors (`mmproj`) and the later parts of a split model
    /// are left out, and so is a path `checkedPath` would refuse.
    public static func findGGUF(roots: [String]) -> [ResearchLocalGGUF] {
        let manager = FileManager.default
        var found: [ResearchLocalGGUF] = []
        var seen = Set<String>()
        var visited = 0

        func scan(_ folder: String, depth: Int) {
            guard depth <= maxDepth,
                  let names = try? manager.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() {
                visited += 1
                if visited > maxEntries { return }
                let path = folder + "/" + name
                guard let type = try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
                else { continue }
                var isFile = type == .typeRegular
                if type == .typeSymbolicLink {
                    // Only a link to a file counts; the target is looked at, not entered.
                    var isFolder: ObjCBool = false
                    isFile = manager.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
                }
                if type == .typeDirectory {
                    if !name.hasPrefix(".") { scan(path, depth: depth + 1) }
                } else if isFile, isModelFile(name), (try? ResearchServerLaunchPlan.checkedPath(path, "")) != nil {
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    guard seen.insert(resolved).inserted,
                          let size = (try? manager.attributesOfItem(atPath: resolved)[.size] as? NSNumber)?.int64Value
                    else { continue }
                    found.append(ResearchLocalGGUF(
                        path: path, name: String(name.dropLast(5)), size: size))
                }
                if visited > maxEntries { return }
            }
        }

        for root in roots { scan(root, depth: 1) }
        return found.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    /// A `.gguf` that can be started by itself: not a vision projector and not
    /// a later part (`-00002-of-00003`) of a split model.
    static func isModelFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".gguf"), !lower.contains("mmproj") else { return false }
        let stem = String(lower.dropLast(5))
        guard let marker = stem.range(of: "-of-", options: .backwards) else { return true }
        let total = stem[marker.upperBound...]
        let part = stem[..<marker.lowerBound].split(separator: "-").last ?? ""
        func isNumber(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
        guard isNumber(total), isNumber(part), let number = Int(part) else { return true }
        return number <= 1
    }

    // MARK: - TUFF

    /// For each folder in `folders`, the installed TUFF models in it: child
    /// folders that hold both `verified-install.json` and `manifest.json`.
    /// A model is named by the `modelID` of its manifest, or by its folder.
    /// Folders without a model are left out.
    public static func findTUFFModels(folders: [String]) -> [ResearchTUFFModelsFolder] {
        let manager = FileManager.default
        var result: [ResearchTUFFModelsFolder] = []
        var seen = Set<String>()
        for folder in folders {
            guard (try? ResearchServerLaunchPlan.checkedPath(folder, "")) != nil,
                  seen.insert(URL(fileURLWithPath: folder).standardizedFileURL.path).inserted,
                  let children = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            var names: [String] = []
            for child in children.sorted() where !child.hasPrefix(".") {
                let path = folder + "/" + child
                var isFolder: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue,
                      manager.fileExists(atPath: path + "/verified-install.json"),
                      manager.fileExists(atPath: path + "/manifest.json") else { continue }
                names.append(modelID(manifest: path + "/manifest.json") ?? child)
            }
            if !names.isEmpty {
                result.append(ResearchTUFFModelsFolder(
                    path: folder, models: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }))
            }
        }
        return result
    }

    /// The `modelID` string of a manifest, or nil when it is missing, too
    /// big, not JSON or empty.
    static func modelID(manifest path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
              size <= maxManifestBytes,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["modelID"] as? String else { return nil }
        let clean = String(ResearchText.terminalSafe(id).prefix(120))
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clean
    }
}
