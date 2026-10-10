import Foundation

/// The sandbox's files on disk: the folder that holds `Scripts/` and
/// `Sandbox/`, laid out like a checkout so that the script finds the build
/// context at `../Sandbox`.
public struct SandboxFiles: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// `SandSeek.app/Contents/Resources/sandbox`, run in place.
        case bundled
        /// A developer's checkout, named by `SANDSEEK_SOURCE_DIR`.
        case checkout
    }

    public let root: URL
    public let origin: Origin

    public init(root: URL, origin: Origin) {
        self.root = root
        self.origin = origin
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

    public var description: String {
        switch self {
        case .noBundledFiles:
            "This build of SandSeek has no sandbox files inside it. Build the app with "
                + "Scripts/package_app.sh, or set \(SandboxResources.overrideVariable) to a "
                + "SandSeek checkout."
        case .notACheckout(let path):
            "\(SandboxResources.overrideVariable) names \(path), which has no "
                + "Scripts/research_sandbox.sh and Sandbox/Containerfile."
        }
    }
}

/// Where the sandbox's files come from. The app carries them in
/// `Contents/Resources/sandbox` (put there by `Scripts/package_app.sh`) and
/// runs the script from there, in place. The folder is part of the signed
/// bundle, so the script that holds every security option of the VM is the
/// app's own, and macOS protects the bundle against changes by other apps. A
/// copy in a folder the user can write to was tried and dropped: the files
/// were checked once, but `container build` and the script ran minutes later
/// from a folder anything could have changed meanwhile. The script and
/// `container build` only read their folder, so there is nothing to copy for.
///
/// For development, the environment variable `SANDSEEK_SOURCE_DIR` can point
/// at a checkout; its files are used in place. It is honoured only in debug
/// builds, or when the app has no sandbox files of its own (`swift run`).
/// A release app ignores it, so a variable that was set for other work (or
/// with `launchctl setenv`) cannot make it run another folder's script.
public struct SandboxResources: Sendable {
    public static let overrideVariable = "SANDSEEK_SOURCE_DIR"

    /// Whether this build lets the variable replace the app's own files.
    public static let overrideAllowedByDefault: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    public let bundledRoot: URL?
    public let environment: [String: String]
    public let allowsOverride: Bool

    public init(bundledRoot: URL? = SandboxResources.defaultBundledRoot(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                allowsOverride: Bool = SandboxResources.overrideAllowedByDefault) {
        self.bundledRoot = bundledRoot
        self.environment = environment
        self.allowsOverride = allowsOverride
    }

    /// `SandSeek.app/Contents/Resources/sandbox`, when the app has it.
    public nonisolated static func defaultBundledRoot(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("sandbox", isDirectory: true)
    }

    /// Whether the app carries its own sandbox files.
    var hasBundledFiles: Bool {
        bundledRoot.map(Self.hasSandbox(at:)) ?? false
    }

    /// The folder the sandbox script runs from.
    public func prepare() throws -> SandboxFiles {
        if let raw = environment[Self.overrideVariable], !raw.isEmpty,
           allowsOverride || !hasBundledFiles {
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
        return SandboxFiles(root: bundledRoot, origin: .bundled)
    }

    /// The script and the build context are both there.
    static func hasSandbox(at root: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(
            atPath: root.appendingPathComponent("Scripts/research_sandbox.sh").path)
            && fileManager.fileExists(
                atPath: root.appendingPathComponent("Sandbox/Containerfile").path)
    }
}
