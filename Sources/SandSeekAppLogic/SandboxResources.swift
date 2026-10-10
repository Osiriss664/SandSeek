import CryptoKit
import Foundation

/// The sandbox's files on disk: the folder that holds `Scripts/` and
/// `Sandbox/`, laid out like a checkout so that the script finds the build
/// context at `../Sandbox`.
public struct SandboxFiles: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// The copy in Application Support, made from the files in the app.
        case installedCopy
        /// A developer's checkout, named by `SANDSEEK_SOURCE_DIR`.
        case checkout
    }

    public let root: URL
    public let origin: Origin
    /// True when this call copied the app's files, because there was no copy
    /// yet or the copy differed from the files in the app.
    public let didCopy: Bool

    public init(root: URL, origin: Origin, didCopy: Bool = false) {
        self.root = root
        self.origin = origin
        self.didCopy = didCopy
    }

    public var script: URL {
        root.appendingPathComponent("Scripts/research_sandbox.sh")
    }

    /// The image's build context; its hash decides whether the image is rebuilt.
    public var sandboxFolder: URL {
        root.appendingPathComponent("Sandbox", isDirectory: true)
    }
}

public enum SandboxResourcesError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The app holds no sandbox files, as when it runs as a bare executable
    /// and not from `SandSeek.app`.
    case noBundledFiles
    /// `SANDSEEK_SOURCE_DIR` does not name a folder with the sandbox in it.
    case notACheckout(String)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .noBundledFiles:
            "This build of SandSeek has no sandbox files inside it. Build the app with "
                + "Scripts/package_app.sh, or set \(SandboxResources.overrideVariable) to a "
                + "SandSeek checkout."
        case .notACheckout(let path):
            "\(SandboxResources.overrideVariable) names \(path), which has no "
                + "Scripts/research_sandbox.sh and Sandbox/Containerfile."
        case .copyFailed(let message):
            "Could not copy the sandbox files to Application Support: \(message)"
        }
    }
}

/// Where the sandbox's files come from. The app carries them in
/// `Contents/Resources/sandbox` (put there by `Scripts/package_app.sh`). On
/// first use, and whenever the files in the app differ from the copy, they
/// are copied to `~/Library/Application Support/SandSeek/Sandbox`, and the
/// script runs from that copy.
///
/// The copy is compared with the files in the app by a hash of every file
/// each time the sandbox is about to be used, not only by a remembered
/// number. A new app version therefore replaces the copy, and so does a copy
/// that was changed afterwards: the script holds every security option of the
/// VM, so a script that is not the app's own is never run.
///
/// For development, the environment variable `SANDSEEK_SOURCE_DIR` can point
/// at a checkout; its files are used in place and nothing is copied.
public struct SandboxResources: Sendable {
    public static let overrideVariable = "SANDSEEK_SOURCE_DIR"

    public let bundledRoot: URL?
    public let installRoot: URL
    public let environment: [String: String]

    public init(bundledRoot: URL? = SandboxResources.defaultBundledRoot(),
                installRoot: URL = SandboxResources.defaultInstallRoot(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.bundledRoot = bundledRoot
        self.installRoot = installRoot
        self.environment = environment
    }

    /// `SandSeek.app/Contents/Resources/sandbox`, when the app has it.
    public nonisolated static func defaultBundledRoot(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("sandbox", isDirectory: true)
    }

    public nonisolated static func defaultInstallRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("SandSeek/Sandbox", isDirectory: true)
    }

    /// Makes sure the files the sandbox runs from are there and are the
    /// app's own, copying them when they are not.
    public func prepare() throws -> SandboxFiles {
        if let raw = environment[Self.overrideVariable], !raw.isEmpty {
            let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            guard Self.hasSandbox(at: root) else {
                throw SandboxResourcesError.notACheckout(root.path)
            }
            return SandboxFiles(root: root, origin: .checkout)
        }
        guard let bundledRoot, Self.hasSandbox(at: bundledRoot) else {
            throw SandboxResourcesError.noBundledFiles
        }
        let wanted = Self.contentHash(of: bundledRoot)
        if !wanted.isEmpty, Self.hasSandbox(at: installRoot),
           Self.contentHash(of: installRoot) == wanted {
            return SandboxFiles(root: installRoot, origin: .installedCopy)
        }
        guard !wanted.isEmpty else { throw SandboxResourcesError.noBundledFiles }
        try copy(from: bundledRoot, expectedHash: wanted)
        return SandboxFiles(root: installRoot, origin: .installedCopy, didCopy: true)
    }

    private func copy(from source: URL, expectedHash: String) throws {
        let fileManager = FileManager.default
        let parent = installRoot.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(installRoot.lastPathComponent)-new-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: staging)
            // The copy is checked before it replaces anything.
            guard Self.contentHash(of: staging) == expectedHash else {
                throw SandboxResourcesError.copyFailed("the copy differs from the original")
            }
            // `attributesOfItem` does not follow a symbolic link, so a link
            // left in the place of the folder is removed as well.
            if (try? fileManager.attributesOfItem(atPath: installRoot.path)) != nil {
                try fileManager.removeItem(at: installRoot)
            }
            try fileManager.moveItem(at: staging, to: installRoot)
        } catch let error as SandboxResourcesError {
            throw error
        } catch {
            throw SandboxResourcesError.copyFailed(error.localizedDescription)
        }
    }

    /// The script and the build context are both there.
    static func hasSandbox(at root: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(
            atPath: root.appendingPathComponent("Scripts/research_sandbox.sh").path)
            && fileManager.fileExists(
                atPath: root.appendingPathComponent("Sandbox/Containerfile").path)
    }

    /// A hash of `Scripts/research_sandbox.sh` and of every file under
    /// `Sandbox/`: their relative paths and their bytes. A changed
    /// Containerfile, server, firewall rule or script changes it. Python's
    /// bytecode caches and Finder's `.DS_Store` do not count.
    public nonisolated static func contentHash(of root: URL) -> String {
        let fileManager = FileManager.default
        var files: [(String, URL)] = []
        // Relative paths straight from the file manager: no path prefix to
        // compare, whatever symbolic links lie above `root` (/var, /tmp).
        for relative in (try? fileManager.subpathsOfDirectory(atPath: root.path)) ?? [] {
            guard relative == "Scripts/research_sandbox.sh" || relative.hasPrefix("Sandbox/")
            else { continue }
            if relative.contains("__pycache__") || relative.hasSuffix(".pyc")
                || relative.hasSuffix(".DS_Store") { continue }
            let url = root.appendingPathComponent(relative)
            // Regular files only; `attributesOfItem` does not follow a link.
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            files.append((relative, url))
        }
        // No file counted: no hash, so two empty folders never look equal.
        guard !files.isEmpty else { return "" }
        var hasher = SHA256()
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
