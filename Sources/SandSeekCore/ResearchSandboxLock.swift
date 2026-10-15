import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Only one SandSeek runs the web sandbox at a time: the app, the `sandseek`
/// command's scripts and a second copy of the app all share one lock, the
/// file `lock` in the sandbox folder (see `ResearchSandboxFiles`).
///
/// It is an operating system lock (`flock`) that belongs to the process that
/// took it: the system drops it when that process ends, however it ends, so a
/// crash never leaves a lock that blocks the next start. The file also holds
/// "<pid> <start time in seconds>" for a plain message and for `status`.
/// A file that names a process which is gone, with nobody holding the lock, is
/// stale: `acquire` takes it over.
///
/// In SandSeek the process that holds the lock is the one `research_sandbox.sh
/// start` leaves running for as long as the VM runs (the script itself ends as
/// soon as the VM is up), so the app learns who owns the sandbox with
/// `status(of:)` and does not take the lock itself. `acquire` is the same
/// lock, written in Swift for anything that does run for as long as it holds
/// it; the tests use it to stand in for the script's holder.
public final class ResearchSandboxLock: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        /// Nobody holds the lock and no process is named in the file.
        case free
        /// A live process holds it. `pid` and `since` are what it wrote, and are
        /// nil when it has not written them yet.
        case held(pid: Int32?, since: Date?)
        /// The file names `pid`, but nobody holds the lock: that process is
        /// gone (or the number was reused for another program). The next
        /// start takes the lock over.
        case stale(pid: Int32)
    }

    /// What a start says when the lock is held.
    public static let busyMessage = "Another SandSeek is using the web sandbox. Close it first, or press Stop in it."

    private let guardLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// "<pid> <seconds>" from the file's text, each part nil when it is not
    /// plain digits.
    static func parseOwner(_ text: String) -> (pid: Int32?, since: Date?) {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let first = words.first, first.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
              let pid = Int32(first), pid > 0 else { return (nil, nil) }
        var since: Date?
        if words.count > 1, words[1].allSatisfy({ $0.isASCII && $0.isWholeNumber }),
           let seconds = Double(words[1]) {
            since = Date(timeIntervalSince1970: seconds)
        }
        return (pid, since)
    }

    /// Reads up to 128 bytes of the lock file from its start.
    private static func ownerText(_ descriptor: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = buffer.withUnsafeMutableBytes { bytes in
            pread(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard count > 0 else { return "" }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    /// Whether the lock in `file` is free, held by a live process, or stale.
    /// A missing file is free. It takes the lock for an instant to find out
    /// and lets go again. The probe is a shared lock (`LOCK_SH`), so several
    /// probes never refuse each other; the holder's exclusive lock
    /// (`LOCK_EX`) still excludes it, and a start in that very instant can
    /// find the file busy for a moment (the script tries again).
    public static func status(of file: URL) -> Status {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return .free }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            let owner = parseOwner(ownerText(descriptor))
            flock(descriptor, LOCK_UN)
            if let pid = owner.pid { return .stale(pid: pid) }
            return .free
        }
        guard errno == EWOULDBLOCK else { return .free }
        let owner = parseOwner(ownerText(descriptor))
        return .held(pid: owner.pid, since: owner.since)
    }

    /// Takes the lock on `file` (made with mode 0600 if it is missing) and
    /// writes `pid` and `now` into it. Nil when a live process holds it, or
    /// the file cannot be opened. Keep the result for as long as the lock
    /// should be held; `release()` (or letting it go) lets go of it.
    public static func acquire(at file: URL, pid: Int32 = getpid(),
                               now: Date = Date()) -> ResearchSandboxLock? {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let line = Array("\(pid) \(Int(now.timeIntervalSince1970))\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = line.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return ResearchSandboxLock(descriptor: descriptor)
    }

    /// Lets go of the lock. The file stays (a new file under the same name
    /// would be a second lock). Safe to call twice.
    public func release() {
        guardLock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
