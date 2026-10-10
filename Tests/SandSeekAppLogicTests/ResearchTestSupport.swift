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
    private(set) var paths: [String] = []
    /// The `Authorization` value of each request, by path, in order.
    private var seenAuthorization: [(path: String, value: String?)] = []

    /// `tuffStatus`: whether `/tuff/v1/status` answers like TUFF. A
    /// `requiredKey` makes `/v1/models` answer 401 unless the request carries
    /// `Authorization: Bearer <key>`, as llama-server does with `--api-key`.
    init(modelReplies: [ResearchHTTPResponse] = [],
         sandboxHealthy: Bool = true,
         listedModels: [String]? = ["gemma-4-e4b-it"],
         tuffStatus: Bool = true,
         requiredKey: String? = nil) {
        self.modelReplies = modelReplies
        self.sandboxHealthy = sandboxHealthy
        self.listedModels = listedModels
        self.tuffStatus = tuffStatus
        self.requiredKey = requiredKey
    }

    func setSandboxHealthy(_ healthy: Bool) { lock.withLock { sandboxHealthy = healthy } }
    func setListedModels(_ models: [String]?) { lock.withLock { listedModels = models } }

    var authorizations: [(path: String, value: String?)] { lock.withLock { seenAuthorization } }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?) async throws -> ResearchHTTPResponse {
        lock.withLock { seenAuthorization.append((url.path, authorization)) }
        return try await respond(url: url, body: body, authorization: authorization)
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        try await respond(url: url, body: body, authorization: nil)
    }

    private func respond(url: URL, body: Data?,
                         authorization: String?) async throws -> ResearchHTTPResponse {
        let json = try body.map { try ResearchJSON.decode($0) }
        return lock.withLock {
            paths.append(url.path)
            switch url.path {
            case "/tuff/v1/status":
                return tuffStatus
                    ? Self.json(.object(["version": .string("8.3.1")]))
                    : ResearchHTTPResponse(status: 404, body: Data())
            case "/v1/chat/completions":
                guard !modelReplies.isEmpty else {
                    return ResearchHTTPResponse(status: 500, body: Data("no reply scripted".utf8))
                }
                return modelReplies.removeFirst()
            case "/v1/models":
                if let requiredKey, authorization != "Bearer " + requiredKey {
                    return ResearchHTTPResponse(status: 401, body: Data(
                        #"{"error":{"message":"Invalid API Key","type":"authentication_error","code":401}}"#.utf8))
                }
                guard let listedModels else { return ResearchHTTPResponse(status: 404, body: Data()) }
                return Self.json(.object([
                    "object": .string("list"),
                    "data": .array(listedModels.map { .object(["id": .string($0)]) }),
                ]))
            case "/health":
                return sandboxHealthy
                    ? Self.json(.object(["status": .string("ok")]))
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

    /// By default every command succeeds, and the in-VM privilege check
    /// reports the unprivileged user the sandbox should run as.
    init(reply: @escaping @Sendable ([String]) -> ResearchProcessResult = FakeProcessRunner.healthy) {
        self.reply = reply
    }

    var commands: [[String]] { lock.withLock { recorded } }

    @Sendable static func healthy(_ command: [String]) -> ResearchProcessResult {
        if command.contains("python3") { return ResearchProcessResult(status: 0, output: "10001 none\n") }
        if command.contains("nft") { return ResearchProcessResult(status: 0, output: firewallListing) }
        return ResearchProcessResult(status: 0, output: "")
    }

    /// What `nft list table inet sandseek_sandbox` prints for firewall.nft with
    /// the Mac as DNS server.
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

    \tset refused6 {
    \t\ttype ipv6_addr
    \t\tflags interval
    \t\telements = { 2001::/32, 2001:db8::/32,
    \t\t\t     2002::/16 }
    \t}

    \tchain output {
    \t\ttype filter hook output priority filter; policy drop;
    \t\tip daddr 192.168.64.1 tcp dport 53 accept
    \t\tip daddr 192.168.64.1 udp dport 53 accept
    \t\toifname "lo" accept
    \t\tct state established,related accept
    \t\tmeta nfproto ipv4 ip daddr @private4 meta l4proto tcp reject with tcp reset
    \t\tmeta nfproto ipv4 ip daddr @private4 reject
    \t\tmeta nfproto ipv4 accept
    \t\tmeta nfproto ipv6 ip6 daddr @refused6 meta l4proto tcp reject with tcp reset
    \t\tmeta nfproto ipv6 ip6 daddr @refused6 reject
    \t\tip6 daddr 2000::/3 accept
    \t\tmeta l4proto tcp reject with tcp reset
    \t\treject
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
             timeout: TimeInterval) async throws -> ResearchProcessResult {
        let command = [executable.lastPathComponent] + arguments
        lock.withLock { recorded.append(command) }
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

/// Sandbox files from `bundle` (a new fake one when none is given), copied
/// to a new install folder; no developer override.
func testResources(bundle: URL? = nil,
                   install: URL = temporaryDirectory("SandSeekInstall")) throws -> SandboxResources {
    SandboxResources(bundledRoot: try bundle ?? fakeSandboxBundle(), installRoot: install,
                     environment: [:])
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

    init(key: String? = nil, failsToSave: Bool = false) {
        self.key = key
        self.failsToSave = failsToSave
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
