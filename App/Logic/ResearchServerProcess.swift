import Darwin
import Foundation

/// What the system says about one running process: enough to tell a model
/// server this app started from the app itself, from the Background API's
/// launch agent, and from an unrelated program that reused the process id.
public struct ResearchProcessInfo: Equatable, Sendable {
    /// The short name (`p_comm`). A symlink to the multi-call TUFF binary
    /// may or may not show its own name here, so it is not relied on.
    public var name: String
    /// When the process started, in microseconds since 1970.
    public var startMicroseconds: Int64
    /// The resolved path of the running executable (`proc_pidpath`).
    public var path: String?
    /// `argv`, as the process was started (`KERN_PROCARGS2`).
    public var arguments: [String]?

    public init(name: String, startMicroseconds: Int64, path: String?, arguments: [String]?) {
        self.name = name
        self.startMicroseconds = startMicroseconds
        self.path = path
        self.arguments = arguments
    }

    /// Reads a running process, or nil when there is none.
    public nonisolated static func read(_ pid: pid_t) -> ResearchProcessInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let started = info.kp_proc.p_un.__p_starttime
        let micros = Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
        return ResearchProcessInfo(
            name: name, startMicroseconds: micros,
            path: executablePath(pid), arguments: processArguments(pid))
    }

    private nonisolated static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private nonisolated static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))?.arguments
    }

    /// Parses the `KERN_PROCARGS2` buffer: an `Int32` argument count, the
    /// executable path, NUL padding, then `argc` NUL-terminated arguments
    /// (the environment follows and is ignored).
    nonisolated static func parseProcessArguments(
        _ buffer: [UInt8]
    ) -> (executablePath: String, arguments: [String])? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return nil }
        var count: Int32 = 0
        withUnsafeMutableBytes(of: &count) { raw in
            for index in 0..<header { raw[index] = buffer[index] }
        }
        guard count >= 0, count <= 4_096 else { return nil }
        var index = header
        func string() -> String {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            let text = String(decoding: buffer[start..<index], as: UTF8.self)
            if index < buffer.count { index += 1 }
            return text
        }
        let path = string()
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<Int(count) {
            guard index < buffer.count else { return nil }
            arguments.append(string())
        }
        return (path, arguments)
    }
}

/// The marker a model server started by this screen leaves behind: its
/// process id and start time. A process id alone can be reused by another
/// program after a crash, and a marker without a start time (the old format)
/// cannot be told from one, so it is never trusted.
struct ResearchServerMarker: Equatable {
    var pid: pid_t
    var startMicroseconds: Int64

    var text: String { "\(pid) \(startMicroseconds)" }

    static func parse(_ text: String) -> ResearchServerMarker? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = pid_t(parts[0]), pid > 1,
              let start = Int64(parts[1]), start > 0 else { return nil }
        return ResearchServerMarker(pid: pid, startMicroseconds: start)
    }

    /// Whether `info` is the server this marker names: the same process
    /// (start time), running the server executable, started as
    /// `TUFFServer --port <port>` and not as the launch agent
    /// (`--background`). The app itself runs the same binary when packaged,
    /// but under another name and without `--port`.
    func names(_ info: ResearchProcessInfo?, executable: URL?, port: Int,
               processID: pid_t = getpid()) -> Bool {
        guard let info, pid != processID, pid > 1,
              info.startMicroseconds == startMicroseconds,
              let executable, let path = info.path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == executable.resolvingSymlinksInPath().path,
              let arguments = info.arguments, let first = arguments.first,
              URL(fileURLWithPath: first).lastPathComponent == "TUFFServer",
              !arguments.contains("--background") else { return false }
        return zip(arguments, arguments.dropFirst()).contains { $0 == "--port" && $1 == String(port) }
    }
}
