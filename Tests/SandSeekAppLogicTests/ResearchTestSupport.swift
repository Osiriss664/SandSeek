import Foundation
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// Answers the model server and the sandbox from scripts, like the fakes in
/// the research loop's own tests.
final class FakeResearchServices: ResearchHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var modelReplies: [ResearchHTTPResponse]
    private var sandboxHealthy: Bool
    private var listedModels: [String]?
    private var tuffStatus: Bool
    private var requiredKey: String?
    private var llamaContext: Int??
    private var isDown = false
    private var chatRequests: [ResearchJSON] = []
    private(set) var paths: [String] = []
    /// The `Authorization` value of each request, by path, in order.
    private var seenAuthorization: [(path: String, value: String?)] = []

    /// `tuffStatus`: whether `/tuff/v1/status` answers like TUFF. A
    /// `requiredKey` makes `/props` answer 401 unless the request carries
    /// `Authorization: Bearer <key>`; `/v1/models` and `/health` stay public,
    /// as in recent llama-server builds (the Mac's llama.cpp probe confirms
    /// that). `llamaContext` makes `/props` answer like llama.cpp, with that
    /// `n_ctx` (`.some(nil)`: llama.cpp without `n_ctx`); nil leaves `/props`
    /// unanswered (404), as TUFF and others do.
    init(modelReplies: [ResearchHTTPResponse] = [],
         sandboxHealthy: Bool = true,
         listedModels: [String]? = ["gemma-4-e4b-it"],
         tuffStatus: Bool = true,
         requiredKey: String? = nil,
         llamaContext: Int?? = nil) {
        self.modelReplies = modelReplies
        self.sandboxHealthy = sandboxHealthy
        self.listedModels = listedModels
        self.tuffStatus = tuffStatus
        self.requiredKey = requiredKey
        self.llamaContext = llamaContext
    }

    func setSandboxHealthy(_ healthy: Bool) { lock.withLock { sandboxHealthy = healthy } }
    func setListedModels(_ models: [String]?) { lock.withLock { listedModels = models } }
    /// While set, every request fails as if nothing listened.
    func setTuffStatus(_ answers: Bool) { lock.withLock { tuffStatus = answers } }
    func setDown(_ down: Bool) { lock.withLock { isDown = down } }
    func clearPaths() { lock.withLock { paths = [] } }

    /// The decoded body of each chat request, in order.
    var chatBodies: [ResearchJSON] { lock.withLock { chatRequests } }

    var authorizations: [(path: String, value: String?)] { lock.withLock { seenAuthorization } }

    /// The `Authorization` value of each signed (sandbox) request, by path, in
    /// order. Kept apart from `authorizations`, which holds the model server's
    /// requests only.
    private var seenSandboxAuthorization: [(path: String, value: String?)] = []
    var sandboxAuthorizations: [(path: String, value: String?)] {
        lock.withLock { seenSandboxAuthorization }
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse {
        lock.withLock { seenAuthorization.append((url.path, authorization)) }
        return try await respond(url: url, body: body, authorization: authorization)
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await respond(url: url, body: body, authorization: nil)
    }

    /// The sandbox's requests carry the signing headers; the answer is signed
    /// as the real sandbox signs it (with `TestSandboxSecret`), from the
    /// request's nonce, method and path.
    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        lock.withLock { seenSandboxAuthorization.append((url.path, authorization)) }
        let response = try await respond(url: url, body: body, authorization: authorization)
        return TestSandboxSecret.signed(response, for: method, url: url, headers: headers)
    }

    private func respond(url: URL, body: Data?,
                         authorization: String?) async throws -> ResearchHTTPResponse {
        let json = try body.map { try ResearchJSON.decode($0) }
        if lock.withLock({ isDown }) { throw URLError(.cannotConnectToHost) }
        return lock.withLock {
            paths.append(url.path)
            switch url.path {
            case "/props":
                if let requiredKey, authorization != "Bearer " + requiredKey {
                    return ResearchHTTPResponse(status: 401, body: Data(
                        #"{"error":{"message":"Invalid API Key","type":"authentication_error","code":401}}"#.utf8))
                }
                guard let llamaContext else { return ResearchHTTPResponse(status: 404, body: Data()) }
                var settings: [String: ResearchJSON] = ["temperature": .number(0.8)]
                if let window = llamaContext { settings["n_ctx"] = .integer(window) }
                return Self.json(.object([
                    "default_generation_settings": .object(settings),
                    "total_slots": .integer(1),
                ]))
            case "/tuff/v1/status":
                return tuffStatus
                    ? Self.json(.object(["version": .string("8.3.1")]))
                    : ResearchHTTPResponse(status: 404, body: Data())
            case "/v1/chat/completions":
                if let json { chatRequests.append(json) }
                guard !modelReplies.isEmpty else {
                    return ResearchHTTPResponse(status: 500, body: Data("no reply scripted".utf8))
                }
                return modelReplies.removeFirst()
            case "/v1/models":
                guard let listedModels else { return ResearchHTTPResponse(status: 404, body: Data()) }
                return Self.json(.object([
                    "object": .string("list"),
                    "data": .array(listedModels.map { .object(["id": .string($0)]) }),
                ]))
            case "/health":
                return sandboxHealthy
                    ? Self.json(.object(["status": .string("ok"), "api": .integer(1)]))
                    : ResearchHTTPResponse(status: 503, body: Data())
            case "/v1/search":
                return Self.json(.object(["results": .array([.object([
                    "title": .string("Apple container"),
                    "url": .string("https://github.com/apple/container"),
                    "snippet": .string("Linux containers as lightweight VMs on your Mac."),
                ])])]))
            case "/v1/fetch":
                return Self.json(.object([
                    "url": json?["url"] ?? .string(""),
                    "title": .string("apple/container"),
                    "text": .string("Each container runs in its own lightweight VM."),
                    "offset": .integer(0),
                    "total_chars": .integer(46),
                ]))
            default:
                return ResearchHTTPResponse(status: 404, body: Data())
            }
        }
    }

    static func json(_ value: ResearchJSON) -> ResearchHTTPResponse {
        ResearchHTTPResponse(status: 200, body: try! value.encoded())
    }

    static func answer(_ text: String, reasoning: String? = nil) -> ResearchHTTPResponse {
        var message: [String: ResearchJSON] = [
            "role": .string("assistant"), "content": .string(text),
        ]
        if let reasoning { message["reasoning_content"] = .string(reasoning) }
        return json(.object(["choices": .array([.object([
            "message": .object(message), "finish_reason": .string("stop"),
        ])])]))
    }

    static func call(_ name: String, _ arguments: String) -> ResearchHTTPResponse {
        json(.object(["choices": .array([.object([
            "message": .object([
                "role": .string("assistant"),
                "content": .null,
                "tool_calls": .array([.object([
                    "id": .string("call-\(name)"),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(name), "arguments": .string(arguments),
                    ]),
                ])]),
            ]),
            "finish_reason": .string("tool_calls"),
        ])])]))
    }
}

/// Records commands instead of running them and answers from a script.
final class FakeProcessRunner: ResearchProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: @Sendable ([String]) -> ResearchProcessResult
    private var recorded: [[String]] = []
    private var recordedEnvironments: [[String: String]] = []
    private var recordedExecutables: [URL] = []

    /// By default every command succeeds, and the in-VM privilege check
    /// reports the unprivileged user the sandbox should run as.
    init(reply: @escaping @Sendable ([String]) -> ResearchProcessResult = FakeProcessRunner.healthy) {
        self.reply = reply
    }

    var commands: [[String]] { lock.withLock { recorded } }
    /// The environment each command ran with, in order.
    var environments: [[String: String]] { lock.withLock { recordedEnvironments } }
    /// The full path of the program each command ran, in order.
    var executables: [URL] { lock.withLock { recordedExecutables } }

    @Sendable static func healthy(_ command: [String]) -> ResearchProcessResult {
        // What Apple's tool says about itself, for `ResearchContainerTool.verify()`.
        if command.first == "codesign", command.contains("-dv") {
            return ResearchProcessResult(status: 0, output: appleSignatureDetails)
        }
        if command.first == "codesign" { return ResearchProcessResult(status: 0, output: "") }
        if command == ["container", "--version"] {
            return ResearchProcessResult(
                status: 0, output: "container CLI version 1.5.0 (build: release, commit: 0123abc)\n")
        }
        if command.contains("python3") { return ResearchProcessResult(status: 0, output: "10001 none\n") }
        if command.contains("nft") { return ResearchProcessResult(status: 0, output: firewallListing) }
        return ResearchProcessResult(status: 0, output: "")
    }

    /// What `codesign -dv --verbose=2` prints for Apple's `container`.
    static let appleSignatureDetails = """
    Executable=/usr/local/bin/container
    Identifier=com.apple.container-cli
    Format=Mach-O thin (arm64)
    Authority=Developer ID Application: Apple Inc. - Containerization (UPBK2H6LZM)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    TeamIdentifier=UPBK2H6LZM

    """

    /// What `nft list table inet sandseek_sandbox` (nft 1.0.9) prints after
    /// `firewall.nft` is loaded with a sample gateway and the commands from
    /// `entrypoint.sh` run with sample values: the Mac as DNS server and some
    /// of the Mac's addresses in the blocked sets. Captured, not hand-written.
    static let firewallListing = """
    table inet sandseek_sandbox {
    \tset private4 {
    \t\ttype ipv4_addr
    \t\tflags interval
    \t\telements = { 0.0.0.0/8, 10.0.0.0/8,
    \t\t\t     100.64.0.0/10, 127.0.0.0/8,
    \t\t\t     169.254.0.0/16, 172.16.0.0/12,
    \t\t\t     192.0.0.0/24, 192.0.2.0/24,
    \t\t\t     192.88.99.0/24, 192.168.0.0/16,
    \t\t\t     198.18.0.0/15, 198.51.100.0/24,
    \t\t\t     203.0.113.0/24, 224.0.0.0/3 }
    \t}

    \tset blocked4 {
    \t\ttype ipv4_addr
    \t\telements = { 10.8.0.2, 127.0.0.1,
    \t\t\t     192.168.64.1, 198.41.0.4,
    \t\t\t     203.0.113.9 }
    \t}

    \tset blocked6 {
    \t\ttype ipv6_addr
    \t\telements = { ::1,
    \t\t\t     2001:db8::1 }
    \t}

    \tset refused6 {
    \t\ttype ipv6_addr
    \t\tflags interval
    \t\telements = { 2001::/32,
    \t\t\t     2001:db8::/32,
    \t\t\t     2002::/16 }
    \t}

    \tchain output {
    \t\ttype filter hook output priority filter; policy drop;
    \t\tip daddr 192.168.64.1 tcp dport 53 accept
    \t\tip daddr 192.168.64.1 udp dport 53 accept
    \t\toifname "lo" accept
    \t\tct state established,related accept
    \t\tip daddr @blocked4 meta l4proto tcp reject with tcp reset
    \t\tip daddr @blocked4 reject with icmp port-unreachable
    \t\tip6 daddr @blocked6 meta l4proto tcp reject with tcp reset
    \t\tip6 daddr @blocked6 reject with icmpv6 port-unreachable
    \t\tip daddr @private4 meta l4proto tcp reject with tcp reset
    \t\tip daddr @private4 reject with icmp port-unreachable
    \t\tmeta nfproto ipv4 accept
    \t\tip6 daddr @refused6 meta l4proto tcp reject with tcp reset
    \t\tip6 daddr @refused6 reject with icmpv6 port-unreachable
    \t\tip6 daddr 2000::/3 accept
    \t\tmeta l4proto tcp reject with tcp reset
    \t\treject
    \t}

    \tchain input {
    \t\ttype filter hook input priority filter; policy drop;
    \t\tiifname "lo" accept
    \t\tct state established,related accept
    \t\tip saddr 192.168.64.1 tcp dport 9100 accept
    \t}
    }

    """

    /// The script commands only: build, start, stop, selftest.
    var scriptCommands: [String] {
        commands.filter { $0.first == "bash" }.compactMap(\.last)
    }

    func run(executable: URL,
             arguments: [String],
             environment: [String: String],
             timeout: TimeInterval,
             killGrace: TimeInterval) async throws -> ResearchProcessResult {
        let command = [executable.lastPathComponent] + arguments
        lock.withLock {
            recorded.append(command)
            recordedEnvironments.append(environment)
            recordedExecutables.append(executable)
        }
        return reply(command)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

func temporaryDirectory(_ name: String = "SandSeekAppTests") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// A folder laid out like the sandbox files in the app (and in a checkout):
/// `Scripts/research_sandbox.sh` and the build context in `Sandbox/`.
func fakeSandboxBundle() throws -> URL {
    let root = temporaryDirectory("SandSeekBundle")
    let sandbox = root.appendingPathComponent("Sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Scripts", isDirectory: true),
        withIntermediateDirectories: true)
    try Data("FROM python\n".utf8).write(to: sandbox.appendingPathComponent("Containerfile"))
    try Data("print('hi')\n".utf8).write(to: sandbox.appendingPathComponent("server.py"))
    try Data("#!/bin/bash\n".utf8).write(
        to: root.appendingPathComponent("Scripts/research_sandbox.sh"))
    return root
}

/// Sandbox files from `bundle` (a new fake one when none is given), run in
/// place; no developer override.
func testResources(bundle: URL? = nil) throws -> SandboxResources {
    SandboxResources(bundledRoot: try bundle ?? fakeSandboxBundle(), environment: [:],
                     allowsOverride: false)
}

/// Settings kept in memory, so tests never touch real preferences.
final class MemorySettings: ResearchSettingsStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func savedString(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func save(_ value: String, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

/// The llama.cpp key kept in memory.
final class MemoryKeyStore: ResearchKeyStoring {
    private let lock = NSLock()
    private var key: String?
    private let failsToSave: Bool
    let keyFilePath: String?

    init(key: String? = nil, failsToSave: Bool = false, filePath: String? = nil) {
        self.key = key
        self.failsToSave = failsToSave
        keyFilePath = filePath
    }

    var stored: String? { lock.withLock { key } }

    func loadKey() -> String? { lock.withLock { key } }

    func saveKey(_ key: String) throws {
        if failsToSave { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { self.key = key }
    }
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool,
               timeout: Duration = .seconds(5)) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() && clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Starting a model server

/// A server process that starts nothing: a test decides when it ends. By
/// default it ends when it gets SIGTERM; `ignoresTerm` makes it need SIGKILL.
final class FakeLaunchedServer: ResearchLaunchedServer, @unchecked Sendable {
    let pid: Int32
    let identity: ResearchProcessIdentity?
    private let lock = NSLock()
    private let ignoresTerm: Bool
    private let onSignal: (@Sendable (String) -> Void)?
    private var ended: ResearchServerExit?
    private var handler: (@Sendable (ResearchServerExit) -> Void)?
    private var received: [String] = []

    init(pid: Int32, path: String, ignoresTerm: Bool = false,
         onSignal: (@Sendable (String) -> Void)? = nil) {
        self.onSignal = onSignal
        self.pid = pid
        identity = ResearchProcessIdentity(startSeconds: 1_000, startMicroseconds: UInt64(pid), path: path)
        self.ignoresTerm = ignoresTerm
    }

    /// "TERM" and "KILL", in the order they arrived.
    var signals: [String] { lock.withLock { received } }
    var exit: ResearchServerExit? { lock.withLock { ended } }

    func terminate() {
        lock.withLock { received.append("TERM") }
        onSignal?("TERM")
        if !ignoresTerm { end(ResearchServerExit(code: 15, bySignal: true)) }
    }

    func forceKill() {
        lock.withLock { received.append("KILL") }
        onSignal?("KILL")
        end(ResearchServerExit(code: 9, bySignal: true))
    }

    func onExit(_ handler: @escaping @Sendable (ResearchServerExit) -> Void) {
        let done = lock.withLock { () -> ResearchServerExit? in
            if ended == nil { self.handler = handler }
            return ended
        }
        if let done { handler(done) }
    }

    func end(_ result: ResearchServerExit) {
        let waiting = lock.withLock { () -> (@Sendable (ResearchServerExit) -> Void)? in
            guard ended == nil else { return nil }
            ended = result
            defer { handler = nil }
            return handler
        }
        waiting?(result)
    }
}

/// Records the plans it is given and starts nothing.
final class FakeServerLauncher: ResearchServerLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var madePlans: [ResearchServerLaunchPlan] = []
    private var madeServers: [FakeLaunchedServer] = []
    /// What the server writes to its log.
    var logText = ""
    /// The server ends at once with this result, as one that cannot bind.
    var endsAtOnce: ResearchServerExit?
    var ignoresTerm = false
    /// Called with "TERM" or "KILL" when a server gets that signal.
    var onSignal: (@Sendable (String) -> Void)?
    var failure: (any Error)?

    var plans: [ResearchServerLaunchPlan] { lock.withLock { madePlans } }
    var servers: [FakeLaunchedServer] { lock.withLock { madeServers } }

    func launch(_ plan: ResearchServerLaunchPlan, log: URL) throws -> any ResearchLaunchedServer {
        if let failure { throw failure }
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(logText.utf8).write(to: log)
        let server = lock.withLock { () -> FakeLaunchedServer in
            let made = FakeLaunchedServer(
                pid: Int32(41_000 + madeServers.count), path: plan.executable,
                ignoresTerm: ignoresTerm, onSignal: onSignal)
            madePlans.append(plan)
            madeServers.append(made)
            return made
        }
        if let endsAtOnce { server.end(endsAtOnce) }
        return server
    }
}

/// Runs `after` once the inner launcher has started a server, for example to
/// make the fake model server start answering.
struct HookedLauncher: ResearchServerLaunching {
    let inner: any ResearchServerLaunching
    let after: @Sendable () -> Void

    func launch(_ plan: ResearchServerLaunchPlan, log: URL) throws -> any ResearchLaunchedServer {
        let server = try inner.launch(plan, log: log)
        after()
        return server
    }
}

/// A launch controller that starts nothing and touches no real settings,
/// state folder or log. It never lists or signals a real process apart from
/// a server it started itself: `childrenOf` and `sendSignal` are fakes.
@MainActor
func testLaunchController(settings: MemorySettings = MemorySettings(),
                          launcher: any ResearchServerLaunching = FakeServerLauncher(),
                          transport: any ResearchHTTPTransport = FakeResearchServices(),
                          stateDirectory: URL = temporaryDirectory(),
                          logURL: URL = temporaryDirectory("SandSeekLog")
                              .appendingPathComponent("model-server.log"),
                          timing: ResearchServerLaunchController.Timing = .init(),
                          identityOf: @escaping @Sendable (Int32) -> ResearchProcessIdentity? = { _ in nil },
                          childrenOf: @escaping @Sendable (Int32) -> [Int32] = { _ in [] },
                          sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = { _, _ in 0 }
) -> ResearchServerLaunchController {
    ResearchServerLaunchController(
        defaults: settings, launcher: launcher, transport: transport,
        stateDirectory: stateDirectory, logURL: logURL,
        timing: timing, identityOf: identityOf, checkProgram: { .success($0) },
        childrenOf: childrenOf, sendSignal: sendSignal)
}

/// The signals a launch controller sent to process ids other than its
/// server's, in order.
final class SentSignals: @unchecked Sendable {
    struct Sent: Equatable {
        let pid: Int32
        let signal: Int32
    }

    private let lock = NSLock()
    private var recorded: [Sent] = []

    var all: [Sent] { lock.withLock { recorded } }

    func send(_ pid: Int32, _ signal: Int32) -> Int32 {
        lock.withLock { recorded.append(Sent(pid: pid, signal: signal)) }
        return 0
    }
}

/// The secret that tests sign with: one file for the whole test run, written
/// the way the launcher writes it (64 hex characters, mode 0600).
enum TestSandboxSecret {
    static let text = String(repeating: "0123456789abcdef", count: 4)
    static let key = Data(text.utf8)

    static let file: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeekTestSecret-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("secret")
        try! Data(text.utf8).write(to: file)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }()

    /// `response` with the signature the sandbox would put on it, when the
    /// request carried a nonce.
    static func signed(_ response: ResearchHTTPResponse, for method: String, url: URL,
                       headers: [String: String]) -> ResearchHTTPResponse {
        guard let nonce = headers[ResearchSandboxSigning.nonceHeader] else { return response }
        var signedHeaders = response.headers
        signedHeaders[ResearchSandboxSigning.answerAuthHeader] = ResearchSandboxSigning.responseAuth(
            key: key, method: method, path: url.path, nonce: nonce,
            status: response.status, body: response.body)
        return ResearchHTTPResponse(status: response.status, body: response.body, headers: signedHeaders)
    }
}

extension ResearchContainerTool {
    /// A tool that passes `verify()` without looking at this Mac: the file
    /// counts as root's, and the commands it runs (`codesign`, `--version`)
    /// are answered by `runner` (a fake that says "Apple, 1.5.0" by default).
    static func trustedForTests(runner: (any ResearchProcessRunning)? = nil,
                                path: String = ResearchContainerTool.installedPath) -> ResearchContainerTool {
        ResearchContainerTool(
            runner: runner ?? FakeProcessRunner(), path: path, environment: [:],
            untrustedPath: { _ in nil }, fileExists: { _ in true }, identity: { _ in "test" })
    }
}
