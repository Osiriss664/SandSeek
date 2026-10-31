import CryptoKit
import Foundation
import Observation
import os
import SandSeekCore

/// The few string settings the controllers remember (the sandbox image's
/// fingerprint, the chosen server, the presets). Tests pass an in-memory
/// store so a run never writes real preferences.
public protocol ResearchSettingsStore {
    func savedString(forKey key: String) -> String?
    func save(_ value: String, forKey key: String)
}

extension UserDefaults: ResearchSettingsStore {
    public func savedString(forKey key: String) -> String? {
        string(forKey: key)
    }

    public func save(_ value: String, forKey key: String) {
        set(value, forKey: key)
    }
}

/// One line of `Scripts/research_sandbox.sh selftest`.
public struct ResearchSelfTestCheck: Equatable, Identifiable, Sendable {
    public enum Outcome: Equatable, Sendable { case passed, failed, warning }
    public let id: Int
    public let section: String
    public let outcome: Outcome
    public let text: String
}

public struct ResearchSelfTestResult: Equatable, Sendable {
    public let passed: Bool
    public let checks: [ResearchSelfTestCheck]
    /// The script's own last line, such as "all sandbox checks passed".
    public let summary: String

    /// Reads the script's output. Failure lines can quote what the sandbox
    /// answered, which can include web text, so every line is cleaned.
    public static func parse(_ output: String, status: Int32) -> ResearchSelfTestResult {
        var checks: [ResearchSelfTestCheck] = []
        var section = ""
        var summary = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = ResearchText.terminalSafe(String(raw))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let outcome: ResearchSelfTestCheck.Outcome?
            let text: String
            if line.hasPrefix("  ok") {
                outcome = .passed
                text = String(trimmed.dropFirst(2))
            } else if line.hasPrefix("  FAIL") {
                outcome = .failed
                text = String(trimmed.dropFirst(4))
            } else if line.hasPrefix("  warn") {
                outcome = .warning
                text = String(trimmed.dropFirst(4))
            } else {
                outcome = nil
                text = trimmed
            }
            if let outcome {
                checks.append(ResearchSelfTestCheck(
                    id: checks.count,
                    section: section,
                    outcome: outcome,
                    text: text.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasSuffix(":") && !line.hasPrefix(" ") {
                section = String(trimmed.dropLast())
            } else {
                summary = trimmed
            }
        }
        let passed = status == 0 && !checks.isEmpty
            && !checks.contains { $0.outcome == .failed }
        return ResearchSelfTestResult(passed: passed, checks: checks, summary: summary)
    }
}

/// Starts and stops the web sandbox VM with the same commands as
/// `Scripts/research_sandbox.sh`, which it runs in place from the app's own
/// sandbox files (see `SandboxResources`). The script
/// holds every security option for the VM, so the app never builds its own
/// `container run` command.
@MainActor @Observable
public final class ResearchSandboxController {
    public enum State: Equatable, Sendable {
        case off
        case preparing
        case starting
        case ready
        case stopping
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .preparing, .starting, .stopping: true
            default: false
            }
        }
    }

    /// Whether the running VM's protection was checked from outside it.
    public enum Protection: Equatable, Sendable {
        case unknown
        case checking
        case verified
        case notVerified(String)
    }

    public static let imageName = "sandseek-sandbox:latest"
    /// The first part of every VM's name. Each start makes a new VM called
    /// `sandseek-sandbox-<8 hex digits>` and records the name (see
    /// `ResearchSandboxFiles`); plain `sandseek-sandbox` is the name SandSeek
    /// 0.1.0 used, which the next start still removes.
    public nonisolated static let containerName = ResearchSandboxFiles.namePrefix
    /// The nft table `firewall.nft` loads inside the VM.
    public static let firewallTable = "sandseek_sandbox"
    /// The port the server and the firewall use inside the VM. On the Mac the
    /// sandbox is on a free port that each start picks and records; this is
    /// also the port assumed when none is recorded.
    public static let port = ResearchSandboxFiles.fallbackPort
    public static let defaultURL = ResearchSandboxFiles.url(port: port)
    static let fingerprintKey = "ResearchSandboxImageFingerprint"
    static let markerName = "sandbox-started-by-app"

    public private(set) var state: State = .off {
        didSet {
            if state != .ready {
                protection = .unknown
                lastSignedCheck = nil
                kernelNotice = nil
            }
        }
    }
    /// Set when the sandbox's Linux kernel is older than the one Apple
    /// container recommends: one plain sentence, with the command that
    /// updates it. The start script finds this out (see `kernelNotice(in:)`);
    /// nil while the sandbox is not ready, when the kernel is current, and
    /// when the script could not tell. Only a warning: nothing is changed.
    public private(set) var kernelNotice: String?
    public private(set) var protection: Protection = .unknown
    /// When the sandbox last answered a signed health check with a signed
    /// answer (the check that decides "running"). Nil while it is not running.
    public private(set) var lastSignedCheck: Date?
    /// Why a sandbox that was running stopped passing the signed health check,
    /// in plain words; nil otherwise. The next passing check clears it.
    public private(set) var lastCheckFailure: String?
    /// True when a sandbox this app started was still running from an
    /// earlier session that did not quit normally.
    public private(set) var adoptedFromLastRun = false
    /// The files the script runs from, once they were prepared.
    public private(set) var files: SandboxFiles?
    public private(set) var selfTest: ResearchSelfTestResult?
    public private(set) var isRunningSelfTest = false
    /// True once this app started the sandbox, so quitting stops it again.
    /// A marker file keeps it across a crash or force-quit.
    public private(set) var startedByApp = false {
        didSet { writeMarker() }
    }
    /// The process that held the sandbox's lock after this app's own start
    /// (the perl process `research_sandbox.sh start` leaves running; see
    /// `ResearchSandboxLock`), kept in the marker file. The app stops, replaces
    /// or quits a sandbox only while that same process holds the lock: if
    /// another SandSeek has the lock now, the VM is theirs, not the app's. Nil
    /// when the app's start left no holder.
    public private(set) var ownedHolderPid: Int32? = nil {
        didSet { writeMarker() }
    }
    /// Fresh VMs this controller has started (`start` and `restart`). The
    /// workspace compares it to know whether a question ran in the current VM.
    public private(set) var freshStarts = 0
    /// What the card says while `restart` builds or starts the VM for the
    /// next question; nil otherwise.
    public private(set) var restartNote: String?
    /// Where the sandbox answers: `baseURL` when one was given (tests), else
    /// the port the last start recorded, read now, else port 9100.
    public var baseURL: URL {
        fixedBaseURL ?? ResearchSandboxFiles.sandboxURL(folder: sandboxFolder, environment: [:])
    }
    private let fixedBaseURL: URL?
    /// The folder with the secret and what the start records beside it.
    private let sandboxFolder: URL
    private let stateDirectory: URL

    private let runner: any ResearchProcessRunning
    /// The one `container` program SandSeek runs (see `ResearchContainerTool`).
    private let containerTool: ResearchContainerTool
    /// Which tool file passed `verify()` this session; nil until it did. A
    /// different file at the same path, or the same file changed, is checked
    /// again before it is run.
    private var verifiedToolIdentity: String?
    private let transport: any ResearchHTTPTransport
    private let defaults: any ResearchSettingsStore
    private let environment: [String: String]
    private let resources: SandboxResources
    /// The secret file the launcher script writes (`ResearchSandboxSecret`).
    /// The health check is signed with it; the app uses the default, and the
    /// tests give each controller a file of their own.
    private let secretFile: URL
    /// The clock for `lastSignedCheck`; tests pass a fixed one.
    private let now: @Sendable () -> Date
    /// Whether process `pid` is the lock holder `research_sandbox.sh` left for
    /// the lock file at the given URL (its command line says so). Tests pass
    /// their own.
    private let lockHolderCheck: @Sendable (Int32, URL) -> Bool

    public init(baseURL: URL? = nil,
                runner: any ResearchProcessRunning = FoundationProcessRunner(),
                containerTool: ResearchContainerTool? = nil,
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 3),
                defaults: any ResearchSettingsStore = UserDefaults.standard,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                resources: SandboxResources = SandboxResources(),
                stateDirectory: URL = ResearchSandboxController.defaultStateDirectory(),
                secretFile: URL = ResearchSandboxSecret.defaultFileURL,
                now: @escaping @Sendable () -> Date = { Date() },
                lockHolderCheck: @escaping @Sendable (Int32, URL) -> Bool =
                    ResearchSandboxController.processIsLockHolder) {
        self.fixedBaseURL = baseURL
        self.lockHolderCheck = lockHolderCheck
        self.secretFile = secretFile
        self.sandboxFolder = ResearchSandboxFiles.folder(ofSecretFile: secretFile)
        self.now = now
        self.stateDirectory = stateDirectory
        self.runner = runner
        self.containerTool = containerTool ?? ResearchContainerTool(runner: runner)
        self.transport = transport
        self.defaults = defaults
        self.environment = Self.scriptEnvironment(environment)
        self.resources = resources
        // Both are read before either is set: with @Observable the didSet
        // observers may run here, and the first one rewrites the marker.
        let markerExists = FileManager.default.fileExists(atPath: markerURL.path)
        let markerHolder = markerExists ? Self.markerPid(at: markerURL) : nil
        startedByApp = markerExists
        ownedHolderPid = markerHolder
        adoptedFromLastRun = markerExists
    }

    /// Where the app keeps small state files about what it started.
    public nonisolated static func defaultStateDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("SandSeek/State", isDirectory: true)
    }

    /// The environment the script and `container` run with: the fixed one of
    /// `ResearchCommandEnvironment` (a short PATH of system folders, the home
    /// and temporary folders, the language) plus the few settings the script
    /// reads, `SANDSEEK_DNS` and `SEARXNG_URL`, when `base` has them. Nothing
    /// else of `base` is passed on. In particular `SANDSEEK_SANDBOX_PORT`, which
    /// fixes the script's port for tests, never reaches it: the app lets each
    /// start pick a free port and reads it back from the file the start
    /// writes, so a value exported for command line work must not pin the
    /// app's VM to one port. The source folder override (which the app
    /// resolves itself) never reaches the script either.
    static func scriptEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = ResearchCommandEnvironment.environment(base: base)
        for name in ResearchCommandEnvironment.sandboxScriptNames {
            if let value = base[name], !value.isEmpty { environment[name] = value }
        }
        return environment
    }

    /// The name of the VM to talk to: the one the last start recorded, else
    /// the plain name SandSeek 0.1.0 used.
    private func vmName() -> String {
        let recorded = try? ResearchSandboxFiles.readName(in: sandboxFolder)
        return recorded ?? Self.containerName
    }

    private var lockFile: URL { ResearchSandboxFiles.lockFile(in: sandboxFolder) }

    /// The `container` program to run, after checking it. The check is made
    /// once per session and again only if the file at its path is not the one
    /// that was checked. A failure is returned as the error to show.
    private func trustedContainer() async throws -> URL {
        if let verifiedToolIdentity, containerTool.currentIdentity() == verifiedToolIdentity {
            return containerTool.url
        }
        verifiedToolIdentity = nil
        try await containerTool.verify()
        verifiedToolIdentity = containerTool.currentIdentity()
        return containerTool.url
    }

    private var markerURL: URL { stateDirectory.appendingPathComponent(Self.markerName) }

    /// The marker is empty, or holds the lock holder's pid and a line break.
    private func writeMarker() {
        if startedByApp {
            try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let text = ownedHolderPid.map { "\($0)\n" } ?? ""
            FileManager.default.createFile(atPath: markerURL.path, contents: Data(text.utf8))
        } else {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    /// The pid a marker file holds: digits only, nil for an empty marker or
    /// anything else.
    static func markerPid(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url), data.count <= 16 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
              let pid = Int32(text), pid > 0 else { return nil }
        return pid
    }

    /// The app no longer owns a sandbox: forgets the marker and the holder.
    private func dropOwnership() {
        ownedHolderPid = nil
        startedByApp = false
        adoptedFromLastRun = false
    }

    /// Who holds the sandbox's lock, as far as this app is concerned.
    enum LockOwner: Equatable {
        /// Nobody (the lock is free, or its process is gone).
        case nobody
        /// The process this app recorded after its own start.
        case thisApp
        /// Another process: another SandSeek, or a start still writing its pid.
        case someoneElse
    }

    func lockOwner() -> LockOwner {
        switch ResearchSandboxLock.status(of: lockFile) {
        case .free, .stale:
            return .nobody
        case .held(let pid, _):
            if let pid, let ownedHolderPid, pid == ownedHolderPid { return .thisApp }
            return .someoneElse
        }
    }

    /// True when `pid` is a lock holder that `research_sandbox.sh` made for
    /// `lockFile`: its command line has the holder's marker word and the lock
    /// file's path, as the script checks before it ends one.
    public nonisolated static func processIsLockHolder(_ pid: Int32, lockFile: URL) -> Bool {
        guard pid > 0,
              let result = runAndWait("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)],
                                      environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                                      timeout: 3),
              result.status == 0 else { return false }
        return result.output.contains("sandseek-lock-holder") && result.output.contains(lockFile.path)
    }

    /// After a start attempt, however it ended (it can end by the app's time
    /// limit, which kills the script before it can clean up and leaves its lock
    /// holder running): if a holder this attempt made holds the lock, remember
    /// it as the app's own, so the next start, Stop and quitting deal with it.
    /// A holder older than the attempt is not the app's. After a start that
    /// did not succeed, the holder's command line must also be the script's
    /// (`verify`); a start that succeeded took the lock itself.
    private func adoptHolder(since began: Date, verify: Bool) {
        guard case .held(let pidOrNil, let sinceOrNil) = ResearchSandboxLock.status(of: lockFile),
              let pid = pidOrNil, let since = sinceOrNil,
              Int(since.timeIntervalSince1970) >= Int(began.timeIntervalSince1970) - 2,
              !verify || lockHolderCheck(pid, lockFile) else { return }
        ownedHolderPid = pid
        startedByApp = true
    }

    /// Finds the files the script runs from: the app's own, in place in the
    /// bundle, or the checkout named by `SANDSEEK_SOURCE_DIR` where that is
    /// allowed (see `SandboxResources`). Sets the state to a failure with the
    /// reason when `reportFailure` is set and the files are not available.
    @discardableResult
    private func prepareFiles(reportFailure: Bool) -> SandboxFiles? {
        do {
            let prepared = try resources.prepare()
            files = prepared
            return prepared
        } catch {
            files = nil
            if reportFailure { state = .failed(String(describing: error)) }
            return nil
        }
    }

    /// Asks the sandbox whether it answers. Leaves a start or stop in
    /// progress, and a failure message, alone.
    public func refresh() async {
        guard !state.isBusy else { return }
        let problem = await healthProblem()
        guard !state.isBusy else { return }
        if problem == nil {
            state = .ready
            if protection == .unknown { await verifyProtection() }
        } else {
            if state == .ready {
                state = .off
                lastCheckFailure = Self.checkFailureText(problem)
            }
            if adoptedFromLastRun {
                // The marker outlived the VM. Nothing is left to stop unless
                // the holder this app started is still there: that one is
                // kept, for Stop, quitting and the next start to deal with.
                adoptedFromLastRun = false
                if lockOwner() != .thisApp {
                    ownedHolderPid = nil
                    startedByApp = false
                }
            }
        }
    }

    /// Checks from outside the VM that its firewall is loaded and that the
    /// web server runs as the unprivileged user with no capabilities. The
    /// screen only allows questions once this passes, whatever the folder's
    /// script did, and it also shows that the recorded port really is this sandbox.
    public func verifyProtection() async {
        guard state == .ready, protection != .checking else { return }
        protection = .checking
        let container: URL
        do {
            container = try await trustedContainer()
        } catch {
            guard state == .ready else { return }
            protection = .notVerified(String(describing: error))
            return
        }
        let vm = vmName()
        let firewall = try? await runner.run(
            executable: container,
            arguments: ["exec", vm,
                        "nft", "list", "table", "inet", Self.firewallTable],
            environment: environment, timeout: 30)
        guard state == .ready else { return }
        guard let firewall, firewall.status == 0 else {
            protection = .notVerified("The sandbox's firewall is not loaded, or this is not "
                + "the SandSeek sandbox. Stop it, then start it again.")
            return
        }
        if let problem = Self.firewallProblem(firewall.output) {
            protection = .notVerified("The sandbox's firewall is loaded but \(problem). "
                + "Check that SandSeek is up to date, then start the sandbox again.")
            return
        }
        let privileges = try? await runner.run(
            executable: container,
            arguments: ["exec", vm,
                        "python3", "-c", Self.privilegeCheck],
            environment: environment, timeout: 30)
        guard state == .ready else { return }
        let found = privileges?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard privileges?.status == 0, found == "10001 none" else {
            protection = .notVerified("The sandbox's web server is not running as the "
                + "unprivileged user without capabilities (found: \(found.isEmpty ? "nothing" : String(found.prefix(80)))).")
            return
        }
        protection = .verified
    }

    /// Checks the protection again, for example right before a question, so
    /// a VM replaced since the last check is not trusted on the old result.
    public func recheckProtection() async {
        guard state == .ready, protection != .checking else { return }
        protection = .unknown
        await verifyProtection()
    }

    /// The private ranges `firewall.nft` must refuse: the Mac (the VM's
    /// gateway), the local network, carrier-grade NAT, loopback, link-local
    /// and cloud metadata addresses, and multicast and reserved space.
    static let requiredRefusedRanges = [
        "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3",
    ]

    /// Reads `nft list table inet sandseek_sandbox` (plain: since nft 0.9.1,
    /// `-n` prints every protocol, state and ICMP code as a number, which the
    /// checks below would not recognise) and says what is wrong with it, or nil
    /// when it has the shape `firewall.nft` gives it. Outbound: traffic dropped unless allowed, the
    /// private ranges and the Mac's own addresses (the sets `blocked4` and
    /// `blocked6`, filled at start) refused, and no rule but SandSeek's own:
    /// loopback, replies, DNS to the name servers, one SearXNG address and
    /// port, and public addresses after the refusals. Inbound: traffic dropped
    /// unless it is loopback, a reply, or a new connection to port 9100 from
    /// one IPv4 address (the VM's default gateway).
    static func firewallProblem(_ listing: String) -> String? {
        let lines = listing.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.contains("jump ") || $0.contains("goto ") }) {
            return "sends traffic to other rules SandSeek does not check"
        }
        guard let chainStart = lines.firstIndex(where: {
            $0.contains("hook output") && $0.contains("policy drop")
        }) else {
            return "does not drop outbound traffic by default"
        }
        guard let setStart = lines.firstIndex(of: "set private4 {"),
              let setEnd = lines[setStart...].firstIndex(of: "}") else {
            return "has no set of refused private addresses"
        }
        let refused = Set(lines[setStart..<setEnd].joined(separator: " ")
            .split { !"0123456789./".contains($0) }.map(String.init))
        if let missing = requiredRefusedRanges.first(where: { !refused.contains($0) }) {
            return "does not list \(missing) among the refused addresses"
        }
        // The Mac's own addresses, which the private ranges do not cover when
        // one is public. The IPv4 set always holds some (the start adds a test
        // address); the IPv6 set can be empty on a Mac without IPv6.
        guard let blockedStart = lines.firstIndex(of: "set blocked4 {"),
              let blockedEnd = lines[blockedStart...].firstIndex(of: "}"),
              lines.contains("set blocked6 {") else {
            return "has no sets of the Mac's own addresses"
        }
        guard lines[blockedStart..<blockedEnd].contains(where: { $0.hasPrefix("elements") }) else {
            return "refuses none of the Mac's own addresses"
        }
        // Every rule in the chain must be one firewall.nft or entrypoint.sh
        // writes, so nothing can allow traffic before or after the refusal.
        var refusesPrivate4 = false
        var refusesRefused6 = false
        var refusesBlocked4 = false
        var refusesBlocked6 = false
        var dnsAddresses: Set<String> = []
        var otherExceptions: [String] = []
        for line in lines[(chainStart + 1)...] {
            if line == "}" { break }
            if line.isEmpty { continue }
            if line.contains("!=") || line.contains("comment") {
                return "has a rule SandSeek does not expect (\(String(line.prefix(80))))"
            }
            if isRefusal(line) {
                // Only a refusal of every destination in the set counts.
                if line.wholeMatch(of: #/(?:meta nfproto ipv4 )?ip daddr @private4 (?:meta l4proto tcp |ip protocol tcp )?reject(?: with [a-z0-9 -]+)?/#) != nil {
                    refusesPrivate4 = true
                }
                if line.wholeMatch(of: #/(?:meta nfproto ipv6 )?ip6 daddr @refused6 (?:meta l4proto tcp |ip6 nexthdr tcp )?reject(?: with [a-z0-9 -]+)?/#) != nil {
                    refusesRefused6 = true
                }
                if line.wholeMatch(of: #/(?:meta nfproto ipv4 )?ip daddr @blocked4 (?:meta l4proto tcp |ip protocol tcp )?reject(?: with [a-z0-9 -]+)?/#) != nil {
                    refusesBlocked4 = true
                }
                if line.wholeMatch(of: #/(?:meta nfproto ipv6 )?ip6 daddr @blocked6 (?:meta l4proto tcp |ip6 nexthdr tcp )?reject(?: with [a-z0-9 -]+)?/#) != nil {
                    refusesBlocked6 = true
                }
                continue
            }
            if line == "oifname \"lo\" accept" || line == "ct state established,related accept" {
                continue
            }
            if let exception = singleAddressException(line) {
                if exception.port == "53" || exception.port == "domain" {
                    dnsAddresses.insert(exception.address)
                } else {
                    otherExceptions.append(exception.address)
                }
                continue
            }
            if line == "meta nfproto ipv4 accept", refusesPrivate4, refusesBlocked4 { continue }
            if ["ip6 daddr 2000::/3 accept", "meta nfproto ipv6 ip6 daddr 2000::/3 accept"]
                .contains(line), refusesRefused6, refusesBlocked6 {
                continue
            }
            return "allows more than SandSeek's own rules (\(String(line.prefix(80))))"
        }
        guard refusesPrivate4 else { return "does not refuse the private addresses" }
        guard refusesBlocked4, refusesBlocked6 else {
            return "does not refuse the Mac's own addresses"
        }
        // Only SearXNG gets a port other than DNS, and never on a DNS
        // server's address, which by default is the Mac.
        if otherExceptions.count > 1
            || otherExceptions.contains(where: { dnsAddresses.contains($0) }) {
            return "allows more than DNS to the Mac or extra addresses"
        }
        return inputChainProblem(lines)
    }

    /// The input chain `firewall.nft` writes: policy drop, loopback and
    /// replies accepted, and new connections accepted on port 9100 (the port
    /// inside the VM, whatever port the Mac publishes it on) from one
    /// IPv4 address only, the VM's default gateway (the address the published
    /// port connects from). nft may print port 9100 by its service name. Any
    /// other rule, or none for port 9100, is a
    /// problem: another rule could open a port to the local network.
    private static func inputChainProblem(_ lines: [String]) -> String? {
        guard let start = lines.firstIndex(where: {
            $0.contains("hook input") && $0.contains("policy drop")
        }) else {
            return "does not drop inbound traffic by default"
        }
        var gatewayRules = 0
        for line in lines[(start + 1)...] {
            if line == "}" { break }
            if line.isEmpty { continue }
            if line == "iifname \"lo\" accept" || line == "ct state established,related accept" {
                continue
            }
            if line.wholeMatch(of: #/ip saddr (?:[0-9]{1,3}\.){3}[0-9]{1,3} tcp dport (?:9100|jetdirect) accept/#) != nil {
                gatewayRules += 1
                continue
            }
            return "accepts more inbound traffic than SandSeek's own rules (\(String(line.prefix(80))))"
        }
        guard gatewayRules == 1 else {
            return "does not accept port 9100 from the gateway alone"
        }
        return nil
    }

    /// `reject`, or a rule ending in it, such as
    /// `ip daddr @private4 meta l4proto tcp reject with tcp reset`.
    private static func isRefusal(_ line: String) -> Bool {
        guard !line.contains("accept") else { return false }
        return line.wholeMatch(of: #/(?:.* )?(?:reject(?: with [a-z0-9 -]+)?|drop)/#) != nil
    }

    /// `ip daddr 192.168.64.1 udp dport 53 accept` and the like: one address,
    /// one protocol, one port. Returns the address and the port.
    private static func singleAddressException(
        _ line: String
    ) -> (address: String, port: String)? {
        var rule = Substring(line)
        for prefix in ["meta nfproto ipv4 ", "meta nfproto ipv6 "] where rule.hasPrefix(prefix) {
            rule = rule.dropFirst(prefix.count)
        }
        let words = rule.split(separator: " ").map(String.init)
        guard words.count == 7, ["ip", "ip6"].contains(words[0]), words[1] == "daddr",
              ["tcp", "udp"].contains(words[3]), words[4] == "dport",
              words[6] == "accept", isPort(words[5])
        else { return nil }
        let address = words[2]
        guard !address.isEmpty,
              address.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else { return nil }
        return (address: address, port: words[5])
    }

    /// A port number, or a service name such as `domain` or `http-alt` if nft
    /// prints one.
    private static func isPort(_ word: String) -> Bool {
        if let port = Int(word) { return (1...65_535).contains(port) }
        return !word.isEmpty && word.first!.isLetter && word.allSatisfy {
            ($0.isLetter && $0.isLowercase) || $0.isNumber || "-_.+".contains($0)
        }
    }

    /// The same check `research_sandbox.sh selftest` runs: the user id and
    /// any capability sets of the process running /app/server.py.
    static let privilegeCheck = """
    import glob
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            if b"/app/server.py" not in open(path, "rb").read().split(b"\\0"):
                continue
            status = dict(l.split(":", 1) for l in open(path[:-7] + "status") if ":" in l)
        except OSError:
            continue
        caps = [n for n in ("CapPrm", "CapEff", "CapBnd", "CapAmb") if int(status[n], 16)]
        print(status["Uid"].split()[0], ",".join(caps) or "none")
        break
    """

    /// What the card says when a running sandbox stops passing the check, in
    /// one short sentence (plus the reason when it is not simply "gone").
    static func checkFailureText(_ problem: ResearchError?) -> String {
        switch problem {
        case .none, .some(.sandboxUnavailable):
            return "The sandbox stopped answering."
        case .some(.sandboxNotSigned):
            return "Something answered on the sandbox\u{2019}s port without SandSeek\u{2019}s signature."
        case .some(let other):
            let reason = other.description
            return "The sandbox check failed. " + reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }

    /// "checked 14:05": the time of a passing signed health check, as the card
    /// shows it. It follows the Mac's 12 or 24 hour setting (`locale`).
    public nonisolated static func checkedLabel(
        for date: Date, timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let style = Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale,
            calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
        return "checked " + date.formatted(style)
    }

    /// True when the sandbox runs but its last security check failed. The
    /// card must not look fine then, whether it is folded or not.
    public var securityCheckFailed: Bool {
        state == .ready && selfTest?.passed == false
    }

    /// Whether the card may say "Signed": the sandbox is ready, its protection
    /// was verified, no security check failed, and a signed health check passed.
    public var showsSignedSeal: Bool {
        state == .ready && protection == .verified && !securityCheckFailed
            && lastSignedCheck != nil
    }

    /// Why the sandbox does not count as running: nil when it answers a signed
    /// `/health` request with a signed 200. No secret file (the sandbox is not
    /// started), a redirect or an answer that is not signed all count as not
    /// running.
    private func healthProblem() async -> ResearchError? {
        do {
            try await ResearchSandboxClient(
                baseURL: baseURL, transport: transport, secretFile: secretFile).checkHealth()
            lastSignedCheck = now()
            lastCheckFailure = nil
            return nil
        } catch let error as ResearchError {
            return error
        } catch {
            return .sandboxUnavailable(error.localizedDescription)
        }
    }

    /// What a failed start adds when something else answers on the port.
    private static func portNote(_ problem: ResearchError) -> String {
        switch problem {
        case .redirectRefused, .sandboxNotSigned, .sandboxSecretUnusable, .sandboxWrongVersion,
             .sandboxClockOff: break
        default: return ""
        }
        let text = problem.description
        return " " + text.prefix(1).uppercased() + text.dropFirst()
    }

    /// What `research_sandbox.sh start` prints (on its error output) when the
    /// kernel is older than the recommended one. Change it with the script.
    nonisolated static let kernelNoticeMarker = "warning: the sandbox runs Linux kernel "

    /// The kernel warning in the script's output, as a sentence for the card,
    /// or nil if there is none.
    nonisolated static func kernelNotice(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(kernelNoticeMarker) {
            let sentence = line.dropFirst("warning: ".count)
            return sentence.prefix(1).uppercased() + sentence.dropFirst()
        }
        return nil
    }

    /// Builds the image when it is missing or the sandbox's files changed
    /// since the last build, then starts a fresh VM.
    public func start() async {
        guard !state.isBusy, state != .ready else { return }
        ServiceLog.logger.notice("Sandbox start requested")
        defer {
            ServiceLog.logger.notice("Sandbox start ended: \(self.state.logName, privacy: .public)")
        }
        guard let files = prepareFiles(reportFailure: true) else { return }
        let script = files.script
        selfTest = nil
        lastCheckFailure = nil
        // One SandSeek at a time. If another one holds the sandbox's lock, say
        // so now instead of building an image first. (The script takes the
        // lock itself and decides again; this only saves the wait.)
        // (A sandbox this app started earlier and that no longer answers may
        // still hold it: that one is the app's own to replace, but only while
        // the process that holds the lock is the one this app recorded.)
        if lockOwner() == .someoneElse {
            if startedByApp { dropOwnership() }
            state = .failed(ResearchSandboxLock.busyMessage)
            return
        }
        // Before anything is built or started: only Apple's tool is run.
        state = .preparing
        let container: URL
        do {
            container = try await trustedContainer()
        } catch {
            state = .failed(String(describing: error))
            return
        }
        let fingerprint = Self.fingerprint(of: files.sandboxFolder)
        if await needsBuild(fingerprint: fingerprint, container: container) {
            state = .preparing
            guard let built = await runScript(script, "build") else { return }
            guard built.status == 0 else {
                state = .failed(Self.message(for: built, doing: "build the sandbox image"))
                return
            }
            defaults.save(fingerprint, forKey: Self.fingerprintKey)
        }
        state = .starting
        guard let started = await runStart(script) else { return }
        guard started.status == 0 else {
            state = .failed(Self.message(for: started, doing: "start the sandbox"))
            return
        }
        startedByApp = true
        adoptedFromLastRun = false
        freshStarts += 1
        if let problem = await healthProblem() {
            state = .failed("The sandbox started but does not answer on \(baseURL.absoluteString)."
                + Self.portNote(problem))
            return
        }
        state = .ready
        kernelNotice = Self.kernelNotice(in: started.output)
        await verifyProtection()
    }

    /// Replaces the running VM with a fresh one, for the next question. Not
    /// `stop` then `start`: in between the state would be `.off` (the card
    /// would offer Start, and a click would start the script twice) and the
    /// marker file would be gone, so a crash during the start would leave the
    /// VM running with nobody to stop it. Here the state goes straight to
    /// `.starting`, `startedByApp` and the marker stay, and `start` of the
    /// script does the work: told the pid of the process that holds the lock
    /// for this app's own sandbox (`SANDSEEK_SANDBOX_REPLACE=<pid>`), it ends
    /// that holder only if the lock is held by exactly that process, removes
    /// its VM and makes a new VM with a new name and port. It
    /// rebuilds the image first when the sandbox's files changed. On any
    /// failure the state is `.failed` and no question may start. Does nothing
    /// for a sandbox the app did not start.
    @discardableResult
    public func restart() async -> Bool {
        guard !state.isBusy, startedByApp else { return false }
        // Before any state change: the files are checked against the app's
        // own, and a copy that was altered is replaced.
        guard let files = prepareFiles(reportFailure: true) else { return false }
        let script = files.script
        // The lock must still be held by the process this app recorded (or by
        // nobody). Another SandSeek's sandbox is never replaced.
        if lockOwner() == .someoneElse {
            dropOwnership()
            state = .failed(ResearchSandboxLock.busyMessage)
            return false
        }
        selfTest = nil
        state = .starting
        restartNote = "Restarting the sandbox for this question"
        defer { restartNote = nil }
        let container: URL
        do {
            container = try await trustedContainer()
        } catch {
            state = .failed(String(describing: error))
            return false
        }
        let fingerprint = Self.fingerprint(of: files.sandboxFolder)
        if await needsBuild(fingerprint: fingerprint, container: container) {
            restartNote = "Rebuilding the sandbox"
            state = .preparing
            guard let built = await runScript(script, "build") else { return false }
            guard built.status == 0 else {
                state = .failed(Self.message(for: built, doing: "build the sandbox image"))
                return false
            }
            defaults.save(fingerprint, forKey: Self.fingerprintKey)
            state = .starting
        }
        // The VM that holds the lock is this app's own (checked above, and the
        // script checks the pid again), so the script may end it and take the
        // lock itself in the same call.
        guard let started = await runStart(script) else { return false }
        guard started.status == 0 else {
            state = .failed(Self.message(for: started, doing: "restart the sandbox"))
            return false
        }
        adoptedFromLastRun = false
        freshStarts += 1
        if let problem = await healthProblem() {
            state = .failed("The sandbox restarted but does not answer on \(baseURL.absoluteString)."
                + Self.portNote(problem))
            return false
        }
        state = .ready
        kernelNotice = Self.kernelNotice(in: started.output)
        await verifyProtection()
        return state == .ready && protection == .verified
    }

    public func stop() async {
        guard !state.isBusy else {
            ServiceLog.logger.notice(
                "Sandbox stop ignored, it is \(self.state.logName, privacy: .public)")
            return
        }
        ServiceLog.logger.notice("Sandbox stop requested")
        defer {
            ServiceLog.logger.notice("Sandbox stop ended: \(self.state.logName, privacy: .public)")
        }
        guard let script = prepareFiles(reportFailure: false)?.script else {
            state = .off
            return
        }
        // Only the app's own sandbox is stopped: if another process holds the
        // lock now, the VM is that SandSeek's, and Stop there ends it.
        if lockOwner() == .someoneElse {
            dropOwnership()
            selfTest = nil
            state = .failed("This sandbox belongs to another SandSeek, so it was left running. "
                + "Press Stop in that SandSeek.")
            return
        }
        state = .stopping
        selfTest = nil
        // The script deletes the record of the VM's name, so read it first.
        let vm = vmName()
        guard let stopped = await runScript(script, "stop") else { return }
        guard stopped.status == 0 else {
            state = .failed(Self.message(for: stopped, doing: "stop the sandbox"))
            return
        }
        // The script ignores errors from `container stop` and `delete`, so
        // check that the container is really gone before saying "Off".
        if let problem = await containerLeftOver(named: vm) {
            state = .failed(problem)
            return
        }
        ownedHolderPid = nil
        startedByApp = false
        adoptedFromLastRun = false
        state = .off
    }

    /// Nil when no container called `name` (the VM this app stopped) exists,
    /// running or stopped; otherwise what to tell the user. Other sandbox VMs
    /// are not looked at: they belong to another SandSeek.
    private func containerLeftOver(named name: String) async -> String? {
        let container: URL
        do {
            container = try await trustedContainer()
        } catch {
            return "The sandbox was stopped, but SandSeek could not check that its container is "
                + "gone. \(error)"
        }
        // `--rm` may still be removing the container just after it stopped,
        // so look a few times before calling it left over.
        for attempt in 1...5 {
            let listed = try? await runner.run(
                executable: container,
                arguments: ["list", "--all"],
                environment: environment, timeout: 30)
            guard let listed, listed.status == 0 else {
                return "The sandbox was stopped, but SandSeek could not check that its container is "
                    + "gone. Run `container list --all` in Terminal to look."
            }
            guard Self.listsContainer(listed.output, named: name) else { return nil }
            if attempt < 5 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return "The sandbox's container is still there after stopping. Click Stop again, or run "
            + "`container stop \(name)` and `container delete \(name)` in Terminal."
    }

    /// Whether `name` is a name `start` gives a sandbox VM: `sandseek-sandbox-`
    /// and 8 lower-case hex digits, or the plain `sandseek-sandbox` of 0.1.0.
    /// A container someone started by hand under another name is not one.
    nonisolated static func isSandboxContainer(_ name: String) -> Bool {
        name == containerName || ResearchSandboxFiles.parseName(name) != nil
    }

    /// The IDs in `container list --all` output (the first column of each row;
    /// Apple's `container list` prints the ID first, and if that ever changes
    /// the tests in ResearchAppTests should be updated with the new layout)
    /// that are sandbox VMs. These are the ones the script removes, under the
    /// lock, at the next start.
    nonisolated static func sandboxContainers(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        }.filter { Self.isSandboxContainer($0) }
    }

    /// Whether the output lists a sandbox VM at all.
    nonisolated static func listsContainer(_ output: String) -> Bool {
        !sandboxContainers(in: output).isEmpty
    }

    /// Whether the output lists the VM called `name`.
    nonisolated static func listsContainer(_ output: String, named name: String) -> Bool {
        sandboxContainers(in: output).contains(name)
    }

    public func runSelfTest() async {
        guard state == .ready, !isRunningSelfTest,
              let script = prepareFiles(reportFailure: false)?.script else { return }
        isRunningSelfTest = true
        defer { isRunningSelfTest = false }
        selfTest = nil
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, "selftest"],
                environment: environment, timeout: 300,
                killGrace: ResearchProcessGrace.script)
            selfTest = ResearchSelfTestResult.parse(result.output, status: result.status)
        } catch {
            selfTest = ResearchSelfTestResult(
                passed: false, checks: [],
                summary: "The safety check could not run: \(error.localizedDescription)")
        }
    }

    /// Stops the sandbox while the app quits, waiting a few seconds for it.
    /// The marker is only removed once the container is confirmed gone, so
    /// the next launch can still take over anything left running.
    public func stopWhenQuitting() {
        guard startedByApp, let script = prepareFiles(reportFailure: false)?.script else { return }
        // Another SandSeek holds the lock now: its VM is not ours to stop.
        if lockOwner() == .someoneElse {
            dropOwnership()
            return
        }
        let vm = vmName()
        guard Self.runAndWait("/bin/bash", [script.path, "stop"],
                              environment: environment, timeout: 20)?.status == 0
        else { return }
        // The list is read only with a tool that passed the check earlier in
        // this session (the quit path cannot wait for the check); without one
        // the marker stays and the next launch looks again. The script's own
        // `stop` above checked the tool itself.
        guard let verifiedToolIdentity, containerTool.currentIdentity() == verifiedToolIdentity
        else { return }
        // Three looks, since `--rm` may still be removing the container.
        for attempt in 1...3 {
            if let listed = Self.runAndWait(containerTool.path, ["list", "--all"],
                                            environment: environment, timeout: 2),
               listed.status == 0, !Self.listsContainer(listed.output, named: vm) {
                ownedHolderPid = nil
                startedByApp = false
                adoptedFromLastRun = false
                return
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
        }
    }

    /// Runs a command synchronously, for the quit path only, and gives up
    /// after `timeout` seconds, leaving the process to finish on its own.
    private nonisolated static func runAndWait(_ executable: String, _ arguments: [String],
                                   environment: [String: String],
                                   timeout: TimeInterval) -> ResearchProcessResult? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return ResearchProcessResult(status: process.terminationStatus,
                                     output: String(decoding: data, as: UTF8.self))
    }

    /// Runs the script's `start` and, whatever came of it, remembers the lock
    /// holder it made (see `adoptHolder`). A busy answer (75) made none.
    private func runStart(_ script: URL) async -> ResearchProcessResult? {
        let began = Date()
        let result = await runScript(script, "start", replacing: ownedHolderPid)
        if result?.status != 75 {
            let succeeded = result?.status == 0 && result?.timedOut != true
            adoptHolder(since: began, verify: !succeeded)
        }
        return result
    }

    private func runScript(_ script: URL, _ command: String,
                           replacing holder: Int32? = nil) async -> ResearchProcessResult? {
        // A first image build downloads Python and its packages.
        let timeout: TimeInterval = command == "build" ? 1_800 : 180
        var environment = self.environment
        if let holder { environment["SANDSEEK_SANDBOX_REPLACE"] = String(holder) }
        do {
            return try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, command],
                environment: environment, timeout: timeout,
                killGrace: ResearchProcessGrace.script)
        } catch {
            state = .failed("Could not run the sandbox script: \(error.localizedDescription)")
            return nil
        }
    }

    private func needsBuild(fingerprint: String, container: URL) async -> Bool {
        guard defaults.savedString(forKey: Self.fingerprintKey) == fingerprint else { return true }
        let inspected = try? await runner.run(
            executable: container,
            arguments: ["image", "inspect", Self.imageName],
            environment: environment, timeout: 60)
        return inspected?.status != 0
    }

    static func message(for result: ResearchProcessResult, doing action: String) -> String {
        let output = ResearchText.terminalSafe(result.output)
        if result.status == 127 || output.contains("Apple container is not installed") {
            return ResearchContainerError.notInstalled.description
        }
        // The script exits with 75 when another SandSeek holds the sandbox.
        if result.status == 75 || output.contains(ResearchSandboxLock.busyMessage) {
            return ResearchSandboxLock.busyMessage
        }
        let tail = ResearchText.terminalSafe(result.tail())
        return tail.isEmpty ? "Could not \(action) (exit \(result.status))."
            : "Could not \(action):\n\(tail)"
    }

    /// A hash of every file in the sandbox folder, so a changed Containerfile,
    /// server or firewall rule triggers a rebuild. Relative paths come from
    /// the file manager, so a symbolic link above the folder (/var, /tmp)
    /// cannot change them.
    public nonisolated static func fingerprint(of directory: URL) -> String {
        let fileManager = FileManager.default
        var files: [(String, URL)] = []
        for relative in (try? fileManager.subpathsOfDirectory(atPath: directory.path)) ?? [] {
            if relative.contains("__pycache__") || relative.hasSuffix(".pyc") { continue }
            let url = directory.appendingPathComponent(relative)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            files.append((relative, url))
        }
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
