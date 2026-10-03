import CryptoKit
import Foundation
import Observation
import TUFFResearchCore

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
/// `Scripts/research_sandbox.sh`, which it runs from the TUFF checkout. The
/// script holds every security option for the VM, so the app never builds
/// its own `container run` command.
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

    public static let imageName = "tuff-web-research:latest"
    public static let containerName = "tuff-web-research"
    public static let defaultURL = URL(string: "http://127.0.0.1:9000")!
    static let repositoryKey = "ResearchRepositoryPath"
    static let fingerprintKey = "ResearchSandboxImageFingerprint"
    static let markerName = "sandbox-started-by-app"

    public private(set) var state: State = .off {
        didSet {
            if state != .ready { protection = .unknown }
        }
    }
    public private(set) var protection: Protection = .unknown
    /// True when a sandbox this app started was still running from an
    /// earlier session that did not quit normally.
    public private(set) var adoptedFromLastRun = false
    public private(set) var repository: URL?
    public private(set) var selfTest: ResearchSelfTestResult?
    public private(set) var isRunningSelfTest = false
    /// True once this app started the sandbox, so quitting stops it again.
    /// A marker file keeps it across a crash or force-quit.
    public private(set) var startedByApp = false {
        didSet { writeMarker() }
    }
    public let baseURL: URL
    private let stateDirectory: URL

    private let runner: any ResearchProcessRunning
    private let transport: any ResearchHTTPTransport
    private let defaults: UserDefaults
    private let environment: [String: String]

    public init(baseURL: URL = ResearchSandboxController.defaultURL,
                runner: any ResearchProcessRunning = FoundationProcessRunner(),
                transport: any ResearchHTTPTransport = URLSessionResearchTransport(timeout: 3),
                defaults: UserDefaults = .standard,
                environment: [String: String] = ResearchCommandEnvironment.environment(),
                searchStart: [URL] = ResearchSandboxController.defaultSearchStart(),
                stateDirectory: URL = ResearchSandboxController.defaultStateDirectory()) {
        self.baseURL = baseURL
        self.stateDirectory = stateDirectory
        self.runner = runner
        self.transport = transport
        self.defaults = defaults
        self.environment = environment
        var candidates = searchStart
        if let saved = defaults.string(forKey: Self.repositoryKey) {
            candidates.insert(URL(fileURLWithPath: saved, isDirectory: true), at: 0)
        }
        repository = candidates.lazy.compactMap {
            Self.findRepository(startingAt: $0, fileExists: FileManager.default.fileExists(atPath:))
        }.first
        // Set directly: didSet observers do not run in an initializer.
        startedByApp = FileManager.default.fileExists(atPath: markerURL.path)
        adoptedFromLastRun = startedByApp
    }

    /// Where the app keeps small state files about what it started.
    public nonisolated static func defaultStateDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("TUFF/Research", isDirectory: true)
    }

    private var markerURL: URL { stateDirectory.appendingPathComponent(Self.markerName) }

    private func writeMarker() {
        if startedByApp {
            try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    /// Where a TUFF checkout is likely to be: above the running app when it
    /// was built from one, then the usual clone location.
    public nonisolated static func defaultSearchStart() -> [URL] {
        var starts: [URL] = []
        if let executable = Bundle.main.executableURL {
            starts.append(executable.deletingLastPathComponent())
        }
        starts.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/TUFF", isDirectory: true))
        return starts
    }

    public nonisolated static func findRepository(startingAt start: URL,
                                                  fileExists: (String) -> Bool) -> URL? {
        var path = start.standardizedFileURL.path
        while true {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            if fileExists(directory.appendingPathComponent("Scripts/research_sandbox.sh").path),
               fileExists(directory.appendingPathComponent("Sandbox/web-research/Containerfile").path) {
                return directory
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == path { return nil }
            path = parent
        }
    }

    /// Uses a folder the person picked. Returns false when it is not a TUFF
    /// checkout with the sandbox in it.
    @discardableResult
    public func chooseRepository(_ url: URL) -> Bool {
        guard let found = Self.findRepository(
            startingAt: url, fileExists: FileManager.default.fileExists(atPath:)) else {
            state = .failed("That folder is not a TUFF checkout with the web sandbox in it.")
            return false
        }
        repository = found
        defaults.set(found.path, forKey: Self.repositoryKey)
        if case .failed = state { state = .off }
        return true
    }

    private var script: URL? {
        repository?.appendingPathComponent("Scripts/research_sandbox.sh")
    }

    /// Asks the sandbox whether it answers. Leaves a start or stop in
    /// progress, and a failure message, alone.
    public func refresh() async {
        guard !state.isBusy else { return }
        let healthy = await isHealthy()
        guard !state.isBusy else { return }
        if healthy {
            state = .ready
            if protection == .unknown { await verifyProtection() }
        } else {
            if state == .ready { state = .off }
            if adoptedFromLastRun {
                // The marker outlived the VM; nothing is left to stop.
                adoptedFromLastRun = false
                startedByApp = false
            }
        }
    }

    /// Checks from outside the VM that its firewall is loaded and that the
    /// web server runs as the unprivileged user with no capabilities. The
    /// screen only allows questions once this passes, whatever the folder's
    /// script did, and it also shows that port 9000 really is this sandbox.
    public func verifyProtection() async {
        guard state == .ready, protection != .checking else { return }
        protection = .checking
        let firewall = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["container", "exec", Self.containerName,
                        "nft", "list", "table", "inet", "tuff_sandbox"],
            environment: environment, timeout: 30)
        guard state == .ready else { return }
        guard let firewall, firewall.status == 0 else {
            protection = .notVerified("The sandbox's firewall is not loaded, or this is not "
                + "the TUFF sandbox. Stop it, then start it again.")
            return
        }
        if let problem = Self.firewallProblem(firewall.output) {
            protection = .notVerified("The sandbox's firewall is loaded but \(problem). "
                + "Check that your TUFF folder is up to date, then start the sandbox again.")
            return
        }
        let privileges = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["container", "exec", Self.containerName,
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

    /// Reads `nft list table inet tuff_sandbox` and says what is wrong with
    /// it, or nil when it has the shape `firewall.nft` gives it: outbound
    /// traffic dropped unless allowed, the private ranges refused, and no
    /// rule but TUFF's own: loopback, replies, DNS to the name servers, one
    /// SearXNG address and port, and public addresses after the refusals.
    static func firewallProblem(_ listing: String) -> String? {
        let lines = listing.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.contains("jump ") || $0.contains("goto ") }) {
            return "sends traffic to other rules TUFF does not check"
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
        // Every rule in the chain must be one firewall.nft or entrypoint.sh
        // writes, so nothing can allow traffic before or after the refusal.
        var refusesPrivate4 = false
        var refusesRefused6 = false
        var dnsAddresses: Set<String> = []
        var otherExceptions: [String] = []
        for line in lines[(chainStart + 1)...] {
            if line == "}" { break }
            if line.isEmpty { continue }
            if line.contains("!=") || line.contains("comment") {
                return "has a rule TUFF does not expect (\(String(line.prefix(80))))"
            }
            if isRefusal(line) {
                // Only a refusal of every destination in the set counts.
                if line.wholeMatch(of: #/(?:meta nfproto ipv4 )?ip daddr @private4 (?:meta l4proto tcp |ip protocol tcp )?reject(?: with [a-z0-9 -]+)?/#) != nil {
                    refusesPrivate4 = true
                }
                if line.wholeMatch(of: #/(?:meta nfproto ipv6 )?ip6 daddr @refused6 (?:meta l4proto tcp |ip6 nexthdr tcp )?reject(?: with [a-z0-9 -]+)?/#) != nil {
                    refusesRefused6 = true
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
            if line == "meta nfproto ipv4 accept", refusesPrivate4 { continue }
            if ["ip6 daddr 2000::/3 accept", "meta nfproto ipv6 ip6 daddr 2000::/3 accept"]
                .contains(line), refusesRefused6 {
                continue
            }
            return "allows more than TUFF's own rules (\(String(line.prefix(80))))"
        }
        guard refusesPrivate4 else { return "does not refuse the private addresses" }
        // Only SearXNG gets a port other than DNS, and never on a DNS
        // server's address, which by default is the Mac.
        if otherExceptions.count > 1
            || otherExceptions.contains(where: { dnsAddresses.contains($0) }) {
            return "allows more than DNS to the Mac or extra addresses"
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

    private func isHealthy() async -> Bool {
        do {
            try await ResearchSandboxClient(baseURL: baseURL, transport: transport).checkHealth()
            return true
        } catch {
            return false
        }
    }

    /// Builds the image when it is missing or the sandbox's files changed
    /// since the last build, then starts a fresh VM.
    public func start() async {
        guard !state.isBusy, state != .ready else { return }
        guard let script, let repository else {
            state = .failed("Choose your TUFF folder so the app can find the web sandbox.")
            return
        }
        selfTest = nil
        let fingerprint = Self.fingerprint(
            of: repository.appendingPathComponent("Sandbox/web-research", isDirectory: true))
        if await needsBuild(fingerprint: fingerprint) {
            state = .preparing
            guard let built = await runScript(script, "build") else { return }
            guard built.status == 0 else {
                state = .failed(Self.message(for: built, doing: "build the sandbox image"))
                return
            }
            defaults.set(fingerprint, forKey: Self.fingerprintKey)
        }
        state = .starting
        guard let started = await runScript(script, "start") else { return }
        guard started.status == 0 else {
            state = .failed(Self.message(for: started, doing: "start the sandbox"))
            return
        }
        startedByApp = true
        adoptedFromLastRun = false
        guard await isHealthy() else {
            state = .failed("The sandbox started but does not answer on \(baseURL.absoluteString).")
            return
        }
        state = .ready
        await verifyProtection()
    }

    public func stop() async {
        guard !state.isBusy else { return }
        guard let script else {
            state = .off
            return
        }
        state = .stopping
        selfTest = nil
        guard let stopped = await runScript(script, "stop") else { return }
        startedByApp = false
        adoptedFromLastRun = false
        state = stopped.status == 0 ? .off
            : .failed(Self.message(for: stopped, doing: "stop the sandbox"))
    }

    public func runSelfTest() async {
        guard state == .ready, !isRunningSelfTest, let script else { return }
        isRunningSelfTest = true
        defer { isRunningSelfTest = false }
        selfTest = nil
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, "selftest"],
                environment: environment, timeout: 300)
            selfTest = ResearchSelfTestResult.parse(result.output, status: result.status)
        } catch {
            selfTest = ResearchSelfTestResult(
                passed: false, checks: [],
                summary: "The safety check could not run: \(error.localizedDescription)")
        }
    }

    /// Stops a sandbox this app started, without waiting, for app quit.
    public func stopWhenQuitting() {
        guard startedByApp, let script else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "stop"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func runScript(_ script: URL, _ command: String) async -> ResearchProcessResult? {
        // A first image build downloads Python and its packages.
        let timeout: TimeInterval = command == "build" ? 1_800 : 180
        do {
            return try await runner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, command],
                environment: environment, timeout: timeout)
        } catch {
            state = .failed("Could not run the sandbox script: \(error.localizedDescription)")
            return nil
        }
    }

    private func needsBuild(fingerprint: String) async -> Bool {
        guard defaults.string(forKey: Self.fingerprintKey) == fingerprint else { return true }
        let inspected = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["container", "image", "inspect", Self.imageName],
            environment: environment, timeout: 60)
        return inspected?.status != 0
    }

    static func message(for result: ResearchProcessResult, doing action: String) -> String {
        let output = ResearchText.terminalSafe(result.output)
        if result.status == 127 || output.contains("Apple container is not installed") {
            return "Apple container is not installed. Install it from github.com/apple/container/releases."
        }
        let tail = ResearchText.terminalSafe(result.tail())
        return tail.isEmpty ? "Could not \(action) (exit \(result.status))."
            : "Could not \(action):\n\(tail)"
    }

    /// A hash of every file in the sandbox folder, so a changed Containerfile,
    /// server or firewall rule triggers a rebuild.
    public nonisolated static func fingerprint(of directory: URL) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        var files: [(String, URL)] = []
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            if relative.contains("__pycache__") || relative.hasSuffix(".pyc") { continue }
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
