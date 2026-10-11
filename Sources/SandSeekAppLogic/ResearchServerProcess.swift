import Foundation
import SandSeekCore

// The model server as a process: starting it, watching it end, and stopping
// it. The controller (ResearchServerLaunchController) works with the two
// protocols below, so its tests use a fake that starts nothing.
//
// SandSeek.app is not sandboxed (no App Sandbox entitlement), which is why
// `Process` can start the program the person chose and a plain path in the
// settings is enough. If the App Sandbox is ever turned on, starting a server
// and the file choosers need rethinking.

/// How a server process ended.
public struct ResearchServerExit: Equatable, Sendable {
    /// The exit code, or the signal number when `bySignal`. Nil when it is
    /// not known (a server taken over after a crash that has since gone).
    public let code: Int32?
    public let bySignal: Bool

    public init(code: Int32?, bySignal: Bool) {
        self.code = code
        self.bySignal = bySignal
    }
}

/// A server process SandSeek can stop. Its state is read from other threads
/// (the termination handler, the quit path), so an implementation guards it
/// with a lock.
public protocol ResearchLaunchedServer: AnyObject, Sendable {
    var pid: Int32 { get }
    /// Who this process is, for the marker file. Nil if it was not readable.
    var identity: ResearchProcessIdentity? { get }
    /// Nil while the process runs.
    var exit: ResearchServerExit? { get }
    /// Sends SIGTERM. Does nothing once the process has ended.
    func terminate()
    /// Sends SIGKILL. Does nothing once the process has ended, so a reused
    /// process id is never signalled.
    func forceKill()
    /// Calls `handler` once, on a background thread, when the process ends
    /// (at once if it already has).
    func onExit(_ handler: @escaping @Sendable (ResearchServerExit) -> Void)
}

public extension ResearchLaunchedServer {
    var hasExited: Bool { exit != nil }
}

public protocol ResearchServerLaunching: Sendable {
    /// Runs the plan with the server's output going to a fresh log file.
    func launch(_ plan: ResearchServerLaunchPlan, log: URL) throws -> any ResearchLaunchedServer
}

public struct FoundationServerLauncher: ResearchServerLaunching {
    public init() {}

    public func launch(_ plan: ResearchServerLaunchPlan,
                       log: URL) throws -> any ResearchLaunchedServer {
        let output = try ResearchServerLog.create(at: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.currentDirectoryURL = log.deletingLastPathComponent()
        let server = FoundationLaunchedServer(process)
        process.terminationHandler = { ended in server.finished(ended) }
        do {
            try process.run()
        } catch {
            try? output.close()
            throw error
        }
        // The server has its own copy of the log now. Keeping ours open would
        // leak one descriptor for every start.
        try? output.close()
        server.recordIdentity()
        return server
    }
}

/// A server this app started with `Process`.
final class FoundationLaunchedServer: ResearchLaunchedServer, @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var ended: ResearchServerExit?
    private var handler: (@Sendable (ResearchServerExit) -> Void)?
    private(set) var identity: ResearchProcessIdentity?

    init(_ process: Process) {
        self.process = process
    }

    var pid: Int32 { process.processIdentifier }
    var exit: ResearchServerExit? { lock.withLock { ended } }

    /// Called right after `run()`, before anyone else sees the server.
    func recordIdentity() {
        identity = ResearchProcessIdentity.read(pid: process.processIdentifier)
    }

    /// The termination handler: Foundation calls it on its own thread, not on
    /// the main actor, so the quit path can poll `exit` while the main thread
    /// is busy.
    func finished(_ finishedProcess: Process) {
        let result = ResearchServerExit(
            code: finishedProcess.terminationStatus,
            bySignal: finishedProcess.terminationReason == .uncaughtSignal)
        let waiting = lock.withLock { () -> (@Sendable (ResearchServerExit) -> Void)? in
            self.ended = result
            defer { handler = nil }
            return handler
        }
        waiting?(result)
    }

    func terminate() {
        guard exit == nil else { return }
        process.terminate()
    }

    func forceKill() {
        guard exit == nil else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func onExit(_ handler: @escaping @Sendable (ResearchServerExit) -> Void) {
        let done = lock.withLock { () -> ResearchServerExit? in
            if ended == nil { self.handler = handler }
            return ended
        }
        if let done { handler(done) }
    }
}

/// A server left running by an earlier SandSeek that did not quit normally,
/// found again through the marker file. It has no `Process`, so before every
/// signal the process id is looked up again: if it no longer has the start
/// time and program the marker names, it is not ours and nothing is sent.
final class AdoptedServer: ResearchLaunchedServer, @unchecked Sendable {
    let pid: Int32
    let identity: ResearchProcessIdentity?
    private let lookup: @Sendable (Int32) -> ResearchProcessIdentity?

    init(pid: Int32, identity: ResearchProcessIdentity,
         lookup: @escaping @Sendable (Int32) -> ResearchProcessIdentity?) {
        self.pid = pid
        self.identity = identity
        self.lookup = lookup
    }

    private var isStillOurs: Bool { lookup(pid) == identity }

    var exit: ResearchServerExit? {
        isStillOurs ? nil : ResearchServerExit(code: nil, bySignal: false)
    }

    func terminate() {
        if isStillOurs { kill(pid, SIGTERM) }
    }

    func forceKill() {
        if isStillOurs { kill(pid, SIGKILL) }
    }

    /// There is no termination handler for a process that is not our child,
    /// so it is looked at every two seconds.
    func onExit(_ handler: @escaping @Sendable (ResearchServerExit) -> Void) {
        Task.detached { [self] in
            while self.exit == nil { try? await Task.sleep(for: .seconds(2)) }
            handler(ResearchServerExit(code: nil, bySignal: false))
        }
    }
}
