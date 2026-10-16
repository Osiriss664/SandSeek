import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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
/// can offer them instead of a file dialog. It only lists folders, looks at
/// the chosen model file and reads one small JSON file per TUFF model: it
/// never writes, downloads or runs anything. A folder that is not on a disk
/// of this Mac (a network share) is not listed, and a file that is only in
/// iCloud (dataless: reading it would download it) is left out. The folders
/// are passed in, so the tests use temporary ones.
public enum ResearchLocalModels {
    /// How deep below a root a file may be, and how many entries the search
    /// looks at in each root. Both keep a search through a big folder short;
    /// the budget is per root, so one big cache cannot hide the others.
    static let maxDepth = 6
    static let maxEntries = 5_000
    /// A manifest larger than this is not read.
    static let maxManifestBytes = 1_000_000
    /// `SF_DATALESS` from `<sys/stat.h>`: the file's contents are not on this
    /// Mac (iCloud, File Provider), and the first read downloads them.
    static let datalessFlag: UInt32 = 0x4000_0000

    // MARK: - Where to look

    /// The folders where llama.cpp, LM Studio and Hugging Face keep `.gguf`
    /// files, below `home`.
    public static func defaultGGUFRoots(home: String) -> [String] {
        [
            "Library/Caches/llama.cpp", ".cache/llama.cpp", ".lmstudio/models",
            ".cache/lm-studio/models", ".cache/huggingface/hub",
        ].map { home + "/" + $0 }
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

    // MARK: - Running a search

    /// The one queue every search runs on, one at a time. A search makes
    /// blocking calls (folder listings, `stat`, a read), which must not hold
    /// one of the few threads Swift concurrency shares with the rest of the
    /// app.
    private static let queue = DispatchQueue(label: "SandSeek.ResearchLocalModels", qos: .utility)

    /// Runs `work` on `queue` and returns what it returns.
    static func onSearchQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - llama.cpp

    /// The `.gguf` files in `roots`, and `chosenModel` itself, sorted by
    /// name, without the same file twice. Only the chosen file is looked at,
    /// never its folder: that can be any folder, such as Downloads or a
    /// network share, which the search has no business listing (and which
    /// would make macOS ask for access). Hidden files and folders below a
    /// root are skipped (a root itself may be hidden, such as `~/.cache`); so
    /// are the `._` files macOS writes on other disks. A link to a regular
    /// file is followed, because a Hugging Face snapshot holds links to its
    /// blobs; a link to a folder is not entered. Vision projectors (`mmproj`)
    /// and the later parts of a split model are left out, and so is a path
    /// `checkedPath` would refuse. A root that is not on a disk of this Mac
    /// is not searched.
    public static func findGGUF(roots: [String], chosenModel: String? = nil) -> [ResearchLocalGGUF] {
        let manager = FileManager.default
        var found: [ResearchLocalGGUF] = []
        // Device and file number of each file listed: the same file through
        // a link, a linked root or a hard link is listed once.
        var seen = Set<String>()
        var visited = 0

        // `stat` follows a link: only one that ends at a regular file whose
        // contents are on this Mac counts, and its size is the target's.
        func add(_ path: String, name: String) {
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !isDataless(info),
                  seen.insert("\(info.st_dev)-\(info.st_ino)").inserted else { return }
            found.append(ResearchLocalGGUF(
                path: path, name: String(name.dropLast(5)), size: Int64(info.st_size)))
        }

        func scan(_ folder: String, depth: Int) {
            guard depth <= maxDepth,
                  let names = try? manager.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                visited += 1
                if visited > maxEntries { return }
                let path = folder + "/" + name
                // The entry itself, not what a link points to.
                guard let type = try? manager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
                else { continue }
                if type == .typeDirectory {
                    scan(path, depth: depth + 1)
                } else if type == .typeRegular || type == .typeSymbolicLink, isModelFile(name),
                          (try? ResearchServerLaunchPlan.checkedPath(path, "")) != nil {
                    add(path, name: name)
                }
                if visited > maxEntries { return }
            }
        }

        // The chosen file first, so that a copy of it in a root (the same
        // file) is the one left out. It is the person's own pick, so it is
        // listed even when `isModelFile` would leave it out.
        if let chosenModel, (try? ResearchServerLaunchPlan.checkedPath(chosenModel, "")) != nil,
           chosenModel.lowercased().hasSuffix(".gguf") {
            add(chosenModel, name: (chosenModel as NSString).lastPathComponent)
        }
        for root in roots where isOnLocalVolume(root) {
            visited = 0
            scan(root, depth: 1)
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
    /// A child that is a link is not entered (`lstat`), so both files are
    /// always the folder's own. A model whose `verified-install.json` is only
    /// in iCloud is left out; a manifest that is only in iCloud is not read.
    /// Folders without a model, and folders not on a disk of this Mac, are
    /// left out.
    public static func findTUFFModels(folders: [String]) -> [ResearchTUFFModelsFolder] {
        let manager = FileManager.default
        var result: [ResearchTUFFModelsFolder] = []
        var seen = Set<String>()
        for folder in folders {
            guard (try? ResearchServerLaunchPlan.checkedPath(folder, "")) != nil,
                  seen.insert(URL(fileURLWithPath: folder).standardizedFileURL.path).inserted,
                  isOnLocalVolume(folder),
                  let children = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            var names: [String] = []
            for child in children.sorted().prefix(maxEntries) where !child.hasPrefix(".") {
                let path = folder + "/" + child
                guard let entry = entryInfo(path), entry.st_mode & S_IFMT == S_IFDIR,
                      let verified = entryInfo(path + "/verified-install.json"),
                      verified.st_mode & S_IFMT == S_IFREG, !isDataless(verified),
                      let manifest = entryInfo(path + "/manifest.json") else { continue }
                let id = isDataless(manifest) ? nil : modelID(manifest: path + "/manifest.json")
                names.append(id ?? child)
            }
            if !names.isEmpty {
                result.append(ResearchTUFFModelsFolder(
                    path: folder, models: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }))
            }
        }
        return result
    }

    /// The `modelID` string of a manifest, or nil when it is missing, too
    /// big, not JSON or empty. The file is opened once and the open file is
    /// checked, so it cannot be swapped between the check and the read. A
    /// link is not followed (`O_NOFOLLOW`), a pipe does not block the open
    /// (`O_NONBLOCK`), and only a regular file whose contents are on this Mac
    /// is read, at most `maxManifestBytes` of it.
    static func modelID(manifest path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !isDataless(info),
              info.st_size <= off_t(maxManifestBytes) else { return nil }
        // One byte more than allowed, so a file that grew is noticed.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxManifestBytes {
            let wanted = min(buffer.count, maxManifestBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count < 0 { return nil }
                break
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count <= maxManifestBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["modelID"] as? String else { return nil }
        let clean = String(ResearchText.terminalSafe(id).prefix(120))
        return clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clean
    }

    // MARK: - Files and disks

    /// What `lstat` says about `path` (the entry itself, not what a link
    /// points to), or nil when there is nothing there.
    static func entryInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    /// True when the contents of the file are not on this Mac (`SF_DATALESS`):
    /// reading it would download it. Always false on a system without file
    /// flags.
    static func isDataless(_ info: stat) -> Bool {
        #if canImport(Darwin)
        return info.st_flags & datalessFlag != 0
        #else
        return false
        #endif
    }

    /// True when `path` is on a disk of this Mac (`MNT_LOCAL`), not on a
    /// network share, where a listing can hang for minutes. False when the
    /// path does not exist. Always true on a system without `statfs` flags.
    static func isOnLocalVolume(_ path: String) -> Bool {
        #if canImport(Darwin)
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        return info.f_flags & UInt32(MNT_LOCAL) != 0
        #else
        return true
        #endif
    }
}
