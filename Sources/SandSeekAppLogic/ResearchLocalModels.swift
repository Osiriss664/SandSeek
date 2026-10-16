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
    /// How deep below a root a file may be, and how many entries the search
    /// looks at in each root. Both keep a search through a big folder short;
    /// the budget is per root, so one big cache cannot hide the others.
    static let maxDepth = 6
    static let maxEntries = 5_000
    /// A manifest larger than this is not read.
    static let maxManifestBytes = 1_000_000

    // MARK: - Where to look

    /// The folders where llama.cpp, LM Studio and Hugging Face keep `.gguf`
    /// files, below `home`.
    public static func defaultGGUFRoots(home: String) -> [String] {
        [
            "Library/Caches/llama.cpp", ".cache/llama.cpp", ".lmstudio/models",
            ".cache/lm-studio/models", ".cache/huggingface/hub",
        ].map { home + "/" + $0 }
    }

    /// The folder of the model chosen last, or nil. It is searched without
    /// its subfolders: it can be any folder, such as the home folder, whose
    /// subfolders are not the search's business (and would make macOS ask
    /// for Documents or Desktop access).
    public static func chosenModelFolder(_ chosenModel: String?) -> String? {
        guard let chosenModel, !chosenModel.isEmpty else { return nil }
        return (chosenModel as NSString).deletingLastPathComponent
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

    /// The `.gguf` files in `roots` (and in `flatFolders`, without their
    /// subfolders), sorted by name, without the same file twice. Hidden files
    /// and folders below a root are skipped (a root itself may be hidden,
    /// such as `~/.cache`); so are the `._` files macOS writes on other
    /// disks. A link to a regular file is followed, because a Hugging Face
    /// snapshot holds links to its blobs; a link to a folder is not entered.
    /// Vision projectors (`mmproj`) and the later parts of a split model are
    /// left out, and so is a path `checkedPath` would refuse.
    public static func findGGUF(roots: [String], flatFolders: [String] = []) -> [ResearchLocalGGUF] {
        let manager = FileManager.default
        var found: [ResearchLocalGGUF] = []
        // Device and file number of each file listed: the same file through
        // a link, a linked root or a hard link is listed once.
        var seen = Set<String>()
        var visited = 0

        func scan(_ folder: String, depth: Int, limit: Int) {
            guard depth <= limit,
                  let names = try? manager.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                visited += 1
                if visited > maxEntries { return }
                let path = folder + "/" + name
                // The entry itself, not what a link points to.
                guard let type = try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
                else { continue }
                if type == .typeDirectory {
                    scan(path, depth: depth + 1, limit: limit)
                } else if type == .typeRegular || type == .typeSymbolicLink, isModelFile(name),
                          (try? ResearchServerLaunchPlan.checkedPath(path, "")) != nil {
                    // `stat` follows a link: only one that ends at a regular
                    // file counts, and its size is the target's.
                    var info = stat()
                    guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          seen.insert("\(info.st_dev)-\(info.st_ino)").inserted else { continue }
                    found.append(ResearchLocalGGUF(
                        path: path, name: String(name.dropLast(5)), size: Int64(info.st_size)))
                }
                if visited > maxEntries { return }
            }
        }

        for folder in flatFolders {
            visited = 0
            scan(folder, depth: 1, limit: 1)
        }
        for root in roots {
            visited = 0
            scan(root, depth: 1, limit: maxDepth)
        }
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
            for child in children.sorted().prefix(maxEntries) where !child.hasPrefix(".") {
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
    /// big, not JSON or empty. Only a regular file is read (`stat` follows a
    /// link, so a link to a big file or to a pipe, which would block the
    /// read, is not).
    static func modelID(manifest path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= off_t(maxManifestBytes),
              let data = FileManager.default.contents(atPath: path),
              data.count <= maxManifestBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["modelID"] as? String else { return nil }
        let clean = String(ResearchText.terminalSafe(id).prefix(120))
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clean
    }
}
