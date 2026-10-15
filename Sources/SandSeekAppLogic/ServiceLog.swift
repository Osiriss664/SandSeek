import os

/// One shared log for what the app starts and stops (the model server, the
/// sandbox), to find out afterwards why something ended. Read it with
/// `log stream --predicate 'subsystem == "io.github.osiriss664.sandseek"'`
/// or in Console. Nothing secret goes in: no keys, no questions, no full
/// paths, and no failure messages (they can quote what a server or the web
/// said), only process ids, exit codes and state names.
enum ServiceLog {
    static let logger = Logger(subsystem: "io.github.osiriss664.sandseek", category: "services")
}

extension ResearchSandboxController.State {
    /// The state's name only; a failure's message stays out of the log.
    var logName: String {
        switch self {
        case .off: "off"
        case .preparing: "preparing"
        case .starting: "starting"
        case .ready: "ready"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}

extension ResearchServerLaunchController.State {
    /// The state's name only; a failure's message stays out of the log.
    var logName: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}
