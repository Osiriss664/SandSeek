import Foundation
@testable import TUFFAppResearch
@testable import TUFFResearchCore

/// Answers the model server and the sandbox from scripts, like the fakes in
/// the research loop's own tests.
final class FakeResearchServices: ResearchHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var modelReplies: [ResearchHTTPResponse]
    private var sandboxHealthy: Bool
    private var listedModels: [String]?
    private(set) var paths: [String] = []

    init(modelReplies: [ResearchHTTPResponse] = [],
         sandboxHealthy: Bool = true,
         listedModels: [String]? = ["gemma-4-e4b-it"]) {
        self.modelReplies = modelReplies
        self.sandboxHealthy = sandboxHealthy
        self.listedModels = listedModels
    }

    func setSandboxHealthy(_ healthy: Bool) { lock.withLock { sandboxHealthy = healthy } }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        let json = try body.map { try ResearchJSON.decode($0) }
        return lock.withLock {
            paths.append(url.path)
            switch url.path {
            case "/v1/chat/completions":
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
        ResearchProcessResult(status: 0, output: command.contains("python3") ? "10001 none\n" : "")
    }

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

func temporaryDirectory(_ name: String = "TUFFResearchTests") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// A folder laid out like a TUFF checkout, as far as the sandbox needs.
func fakeCheckout() throws -> URL {
    let root = temporaryDirectory("TUFFCheckout")
    let sandbox = root.appendingPathComponent("Sandbox/web-research", isDirectory: true)
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

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool,
               timeout: Duration = .seconds(5)) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() && clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
