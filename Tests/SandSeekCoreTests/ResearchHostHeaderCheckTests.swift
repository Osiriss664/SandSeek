import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SandSeekCore

/// Answers each request from a closure and remembers what it was asked.
private final class FakeProber: ResearchHTTPProbing, @unchecked Sendable {
    struct Call: Equatable {
        let port: Int
        let path: String
        let host: String
        let origin: String?
        let authorization: String?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Call) -> ResearchProbeAnswer

    init(_ respond: @escaping @Sendable (Call) -> ResearchProbeAnswer) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { recorded } }

    func get(port: Int, path: String, host: String, origin: String?, authorization: String?,
             timeout: TimeInterval) async -> ResearchProbeAnswer {
        let call = Call(port: port, path: path, host: host, origin: origin,
                        authorization: authorization)
        lock.withLock { recorded.append(call) }
        return respond(call)
    }
}

private func status(_ code: Int, _ headers: [String: String] = [:]) -> ResearchProbeAnswer {
    .status(code: code, headers: headers)
}

private let foreignName = ResearchHostHeaderCheck.foreignHostName

/// A server that answers `normal` to the normal Host and `foreign` to the
/// foreign one (the Origin probe uses the normal Host, so it gets `normal`).
/// A request without the `Authorization` it wants gets `withoutKey`.
private func fakeServer(normal: ResearchProbeAnswer, foreign: ResearchProbeAnswer,
                        wantsKey: String? = nil,
                        withoutKey: ResearchProbeAnswer = .status(code: 401, headers: [:]),
                        originHeaders: [String: String] = [:]) -> FakeProber {
    FakeProber { call in
        if let wantsKey, call.authorization != wantsKey { return withoutKey }
        if call.host.hasPrefix(foreignName) { return foreign }
        if call.origin != nil, case .status(let code, _) = normal {
            return .status(code: code, headers: originHeaders)
        }
        return normal
    }
}

@Suite struct ResearchHostHeaderVerdictTests {
    @Test func aServerThatRefusesAnotherHostChecksIt() async {
        for code in [400, 403, 421] {
            let prober = fakeServer(normal: status(200), foreign: status(code))
            let report = await ResearchHostHeaderCheck.run(
                port: 8080, kind: .tuff, prober: prober)
            #expect(report.verdict == .checksHost, "status \(code)")
            #expect(report.warning == nil)
            #expect(!report.keyEnforced)
        }
    }

    @Test func aServerThatClosesTheConnectionOnAnotherHostChecksIt() async {
        let prober = fakeServer(normal: status(200), foreign: .noAnswer)
        let report = await ResearchHostHeaderCheck.run(port: 8080, kind: nil, prober: prober)
        #expect(report.verdict == .checksHost)
        #expect(report.summary.contains("does not answer"))
    }

    @Test func aServerThatAnswersAnyHostIsReported() async {
        let prober = fakeServer(normal: status(200), foreign: status(200))
        let report = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: prober)
        #expect(report.verdict == .acceptsAnyHost)
        #expect(!report.protectedByKey)
        let warning = report.warning
        #expect(warning == "The server answers requests that name another host "
            + "(Host: sandseek-host-check.invalid). "
            + "A web page could use DNS rebinding to run prompts on it while it runs. "
            + "Quit the server when you are not researching.")
        #expect(report.summary == warning)
    }

    @Test func theTextNamesNoProduct() async {
        let prober = fakeServer(normal: status(200), foreign: status(200))
        let report = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: prober)
        var all: [String] = [report.summary, ResearchHostHeaderCommand.render(report: report).text]
        for kind in [ResearchServerKind.tuff, .ollama, .llamacpp] {
            if let text = report.warningText(for: kind) { all.append(text) }
        }
        for text in all {
            #expect(!text.contains("TUFF"))
            #expect(!text.contains("Ollama"))
        }
    }

    @Test func llamaCppGetsTheKeyFileAdviceAndOthersDoNot() async {
        let prober = fakeServer(normal: status(200), foreign: status(200))
        let report = await ResearchHostHeaderCheck.run(port: 8081, kind: .llamacpp, prober: prober)
        #expect(report.warningText(for: .llamacpp)?.contains("--api-key-file") == true)
        #expect(report.warningText(for: .tuff)?.contains("--api-key-file") == false)
        #expect(report.warningText(for: nil) == report.warning)
    }

    @Test func aServerThatAsksForAKeyIsFineWhenNoKeyWasSent() async {
        let prober = fakeServer(normal: status(401), foreign: status(401))
        let report = await ResearchHostHeaderCheck.run(port: 8081, kind: .llamacpp, prober: prober)
        #expect(report.verdict == .keyRequired)
        #expect(report.keyEnforced)
        #expect(report.warning == nil)
        // The foreign host was still tried; 403 here is reported as a difference.
        let differs = fakeServer(normal: status(403), foreign: status(421))
        let other = await ResearchHostHeaderCheck.run(port: 8081, kind: nil, prober: differs)
        #expect(other.verdict == .keyRequired)
        #expect(other.summary.contains("another host got HTTP 421"))
    }

    @Test func aKeyThatTheServerEnforcesProtectsAnyHostAnswers() async {
        let prober = fakeServer(
            normal: status(200), foreign: status(200), wantsKey: "Bearer secret")
        let report = await ResearchHostHeaderCheck.run(
            port: 8081, kind: .llamacpp, authorization: "Bearer secret", prober: prober)
        #expect(report.verdict == .acceptsAnyHost)
        #expect(report.keySent)
        #expect(report.keyEnforced)
        #expect(report.protectedByKey)
        #expect(report.warning == nil)
        #expect(report.summary.contains("asks for a key"))
    }

    @Test func aKeyThatTheServerDoesNotEnforceDoesNotProtect() async {
        let prober = fakeServer(normal: status(200), foreign: status(200))
        let report = await ResearchHostHeaderCheck.run(
            port: 8081, kind: .llamacpp, authorization: "Bearer secret", prober: prober)
        #expect(report.verdict == .acceptsAnyHost)
        #expect(!report.keyEnforced)
        #expect(!report.protectedByKey)
        #expect(report.warning != nil)
    }

    @Test func theKeyGoesOnlyIntoTheRequestsThatAreMeantToCarryIt() async {
        let prober = fakeServer(normal: status(200), foreign: status(421))
        _ = await ResearchHostHeaderCheck.run(
            port: 8081, kind: .llamacpp, authorization: "Bearer secret", prober: prober)
        let calls = prober.calls
        #expect(calls.count == 4)
        #expect(calls.filter { $0.authorization == nil }.count == 1)
        #expect(calls.filter { $0.authorization == "Bearer secret" }.count == 3)
        // Without a key, three requests and none with an Authorization.
        let plain = fakeServer(normal: status(200), foreign: status(421))
        _ = await ResearchHostHeaderCheck.run(port: 8081, kind: nil, prober: plain)
        #expect(plain.calls.count == 3)
        #expect(plain.calls.allSatisfy { $0.authorization == nil })
    }

    @Test func aRefusedKeyIsUnclear() async {
        let prober = FakeProber { _ in status(401) }
        let report = await ResearchHostHeaderCheck.run(
            port: 8081, kind: .llamacpp, authorization: "Bearer wrong", prober: prober)
        #expect(report.verdict == .unclear)
        #expect(report.summary.contains("refused the key"))
    }

    @Test func aServerThatIsNotRunningIsNotJudged() async {
        let prober = FakeProber { _ in .noAnswer }
        let report = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: prober)
        #expect(report.verdict == .serverNotRunning)
        #expect(report.warning == nil)
        // Only the control was tried.
        #expect(prober.calls.count == 1)
    }

    @Test func oddAnswersAreUnclearAndNameTheStatuses() async {
        let serverError = fakeServer(normal: status(500), foreign: status(500))
        let first = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: serverError)
        #expect(first.verdict == .unclear)
        #expect(first.summary.contains("HTTP 500"))

        let missing = fakeServer(normal: status(404), foreign: status(404))
        let second = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: missing)
        #expect(second.verdict == .unclear)

        let odd = fakeServer(normal: status(200), foreign: status(500))
        let third = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: odd)
        #expect(third.verdict == .unclear)
        #expect(third.summary.contains("HTTP 200"))
        #expect(third.summary.contains("HTTP 500"))

        let redirect = fakeServer(normal: status(200), foreign: status(302))
        let fourth = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: redirect)
        #expect(fourth.verdict == .unclear)
    }

    @Test func aWildcardOriginIsANoteNotTheVerdict() async {
        let prober = fakeServer(
            normal: status(200), foreign: status(421),
            originHeaders: ["access-control-allow-origin": "*"])
        let report = await ResearchHostHeaderCheck.run(port: 8080, kind: .tuff, prober: prober)
        #expect(report.verdict == .checksHost)
        #expect(report.allowsForeignOrigin)
        #expect(report.corsNote?.contains("Access-Control-Allow-Origin") == true)
        #expect(report.warning == nil)
    }

    @Test func anEchoedOriginCountsButAnotherOneDoesNot() async {
        let echoed = fakeServer(
            normal: status(200), foreign: status(421),
            originHeaders: ["access-control-allow-origin":
                                "http://sandseek-host-check.invalid:8080"])
        let first = await ResearchHostHeaderCheck.run(port: 8080, kind: nil, prober: echoed)
        #expect(first.allowsForeignOrigin)
        let other = fakeServer(
            normal: status(200), foreign: status(421),
            originHeaders: ["access-control-allow-origin": "http://localhost:3000"])
        let second = await ResearchHostHeaderCheck.run(port: 8080, kind: nil, prober: other)
        #expect(!second.allowsForeignOrigin)
        #expect(second.corsNote == nil)
        let none = fakeServer(normal: status(200), foreign: status(421))
        let third = await ResearchHostHeaderCheck.run(port: 8080, kind: nil, prober: none)
        #expect(!third.allowsForeignOrigin)
    }

    @Test func aWildcardOriginOnAnErrorReplyDoesNotCount() {
        let report = ResearchHostHeaderReport(
            port: 8080, path: "/v1/models", keySent: false, control: status(200),
            foreignHost: status(421),
            foreignOrigin: status(403, ["access-control-allow-origin": "*"]))
        #expect(!report.allowsForeignOrigin)
    }

    @Test func aWildcardOriginWithAKeyIsNotedAsNeedingOne() async {
        let prober = fakeServer(
            normal: status(200), foreign: status(200), wantsKey: "Bearer k",
            originHeaders: ["access-control-allow-origin": "*"])
        let report = await ResearchHostHeaderCheck.run(
            port: 8081, kind: .llamacpp, authorization: "Bearer k", prober: prober)
        #expect(report.corsNote?.contains("asks for a key") == true)
    }

    @Test func ollamaGetsItsOwnPathAndTheOthersTheModelList() async {
        #expect(ResearchHostHeaderCheck.requestPath(for: .ollama) == "/api/tags")
        #expect(ResearchHostHeaderCheck.requestPath(for: .tuff) == "/v1/models")
        #expect(ResearchHostHeaderCheck.requestPath(for: .llamacpp) == "/v1/models")
        #expect(ResearchHostHeaderCheck.requestPath(for: nil) == "/v1/models")
        let prober = fakeServer(normal: status(200), foreign: status(403))
        let report = await ResearchHostHeaderCheck.run(
            port: 11_434, kind: .ollama, prober: prober)
        #expect(report.path == "/api/tags")
        #expect(prober.calls.allSatisfy { $0.path == "/api/tags" && $0.port == 11_434 })
        let other = fakeServer(normal: status(200), foreign: status(403))
        _ = await ResearchHostHeaderCheck.run(port: 8080, kind: nil, prober: other)
        #expect(other.calls.allSatisfy { $0.path == "/v1/models" })
    }

    @Test func theThreeProbesCarryTheHostsAndTheOriginThatWereMeant() async {
        let prober = fakeServer(normal: status(200), foreign: status(421))
        _ = await ResearchHostHeaderCheck.run(port: 8080, kind: nil, prober: prober)
        let calls = prober.calls
        #expect(calls.count == 3)
        #expect(calls[0] == FakeProber.Call(
            port: 8080, path: "/v1/models", host: "127.0.0.1:8080", origin: nil,
            authorization: nil))
        #expect(calls.contains(FakeProber.Call(
            port: 8080, path: "/v1/models", host: "sandseek-host-check.invalid:8080",
            origin: nil, authorization: nil)))
        #expect(calls.contains(FakeProber.Call(
            port: 8080, path: "/v1/models", host: "127.0.0.1:8080",
            origin: "http://sandseek-host-check.invalid:8080", authorization: nil)))
    }

    @Test func aKeyWithAControlCharacterIsNotSent() async {
        let prober = fakeServer(normal: status(200), foreign: status(421))
        let report = await ResearchHostHeaderCheck.run(
            port: 8080, kind: .llamacpp, authorization: "Bearer a\r\nX-Evil: 1", prober: prober)
        #expect(!report.keySent)
        #expect(prober.calls.allSatisfy { $0.authorization == nil })
    }

    @Test func onlyALoopbackServerAddressIsAccepted() throws {
        let local = try #require(URL(string: "http://127.0.0.1:8080"))
        #expect(ResearchHostHeaderCheck.loopbackAddress(for: local) == .ipv4(127, 0, 0, 1))
        let name = try #require(URL(string: "http://localhost:8080"))
        #expect(ResearchHostHeaderCheck.loopbackAddress(for: name) == .ipv4(127, 0, 0, 1))
        let six = try #require(URL(string: "http://[::1]:8080"))
        #expect(ResearchHostHeaderCheck.loopbackAddress(for: six)?.text == "::1")
        let lan = try #require(URL(string: "http://192.168.1.5:8080"))
        #expect(ResearchHostHeaderCheck.loopbackAddress(for: lan) == nil)
        let remote = try #require(URL(string: "http://example.com:8080"))
        #expect(ResearchHostHeaderCheck.loopbackAddress(for: remote) == nil)
    }
}

@Suite struct ResearchHostHeaderCommandTests {
    private func run(normal: ResearchProbeAnswer, foreign: ResearchProbeAnswer,
                     kind: ResearchServerKind? = nil, authorization: String? = nil,
                     wantsKey: String? = nil,
                     originHeaders: [String: String] = [:]) async
        -> (text: String, exitCode: Int32) {
        await ResearchHostHeaderCommand.run(
            port: 8080, serverKind: kind, authorization: authorization,
            prober: fakeServer(normal: normal, foreign: foreign, wantsKey: wantsKey,
                               originHeaders: originHeaders))
    }

    @Test func aServerThatChecksTheHostExitsZero() async {
        let result = await run(normal: status(200), foreign: status(421))
        #expect(result.exitCode == 0)
        #expect(result.text.contains("Only GET /v1/models was sent; no prompt."))
        #expect(result.text.contains("1. normal request: Host: 127.0.0.1:8080 -> HTTP 200"))
        #expect(result.text.contains(
            "2. another host: Host: sandseek-host-check.invalid:8080 -> HTTP 421"))
        #expect(result.text.contains("3. another origin: Origin: http://sandseek-host-check.invalid:8080 -> HTTP 200"))
        #expect(result.text.contains("RESULT: The server refuses (HTTP 421) a request"))
        #expect(!result.text.contains("4. normal, without the key"))
    }

    @Test func aServerThatAsksForAKeyExitsZero() async {
        let result = await run(normal: status(401), foreign: status(401))
        #expect(result.exitCode == 0)
        #expect(result.text.contains("RESULT: The server asks for a key (HTTP 401 without one)"))
    }

    @Test func aServerThatAnswersAnyHostExitsThree() async {
        let result = await run(normal: status(200), foreign: status(200))
        #expect(result.exitCode == 3)
        #expect(result.text.contains("RESULT: The server answers requests that name another host"))
    }

    @Test func aKeyProtectedServerThatAnswersAnyHostExitsZeroAndShowsTheFourthProbe() async {
        let result = await run(
            normal: status(200), foreign: status(200), authorization: "Bearer topsecret",
            wantsKey: "Bearer topsecret")
        #expect(result.exitCode == 0)
        #expect(result.text.contains("4. normal, without the key: Host: 127.0.0.1:8080 -> HTTP 401"))
        // The key is never printed.
        #expect(!result.text.contains("topsecret"))
    }

    @Test func aServerThatIsNotRunningExitsFour() async {
        let result = await run(normal: .noAnswer, foreign: .noAnswer)
        #expect(result.exitCode == 4)
        #expect(result.text.contains("RESULT: cannot tell. Nothing answers on port 8080."))
        #expect(result.text.contains("2. another host: Host: sandseek-host-check.invalid:8080 -> not sent"))
    }

    @Test func oddAnswersExitFive() async {
        let result = await run(normal: status(500), foreign: status(500))
        #expect(result.exitCode == 5)
        #expect(result.text.contains("RESULT: Cannot tell"))
    }

    @Test func theCorsNoteIsPrintedAndDoesNotChangeTheExitCode() async {
        let result = await run(normal: status(200), foreign: status(421),
                               originHeaders: ["access-control-allow-origin": "*"])
        #expect(result.exitCode == 0)
        #expect(result.text.contains("(allows that origin)"))
        #expect(result.text.contains("NOTE: The server also tells browsers"))
    }

    @Test func ollamaIsAskedForItsTagList() async {
        let result = await run(normal: status(200), foreign: status(403), kind: .ollama)
        #expect(result.exitCode == 0)
        #expect(result.text.contains("Only GET /api/tags was sent; no prompt."))
    }

    @Test func llamaCppAdviceIsInTheExitThreeResult() async {
        let result = await run(normal: status(200), foreign: status(200), kind: .llamacpp)
        #expect(result.exitCode == 3)
        #expect(result.text.contains("--api-key-file"))
    }
}

@Suite struct ResearchHostHeaderRequestTests {
    @Test func theRequestIsPlainHTTPOneOne() throws {
        let bytes = try #require(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: "127.0.0.1:8080", origin: nil, authorization: nil))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text == "GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"
            + "User-Agent: SandSeek host check\r\nAccept: */*\r\nConnection: close\r\n\r\n")
    }

    @Test func originAndAuthorizationAreAddedWhenGiven() throws {
        let bytes = try #require(ResearchHostHeaderRequest.build(
            path: "/api/tags", host: "a.invalid:1", origin: "http://a.invalid:1",
            authorization: "Bearer abc"))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("\r\nOrigin: http://a.invalid:1\r\n"))
        #expect(text.contains("\r\nAuthorization: Bearer abc\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func aLineBreakInAnyValueIsRefused() {
        let evil = "x\r\nX-Injected: 1"
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: evil, origin: nil, authorization: nil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: "h", origin: evil, authorization: nil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: "h", origin: nil, authorization: evil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models HTTP/1.1\r\nX: y", host: "h", origin: nil, authorization: nil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: "h\nX: y", origin: nil, authorization: nil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: "h", origin: nil, authorization: "a\rb") == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "v1/models", host: "h", origin: nil, authorization: nil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/a b", host: "h", origin: nil, authorization: nil) == nil)
        #expect(ResearchHostHeaderRequest.build(
            path: "/v1/models", host: "", origin: nil, authorization: nil) == nil)
    }

    @Test func theRealProberReturnsNoAnswerForARefusedValue() async {
        let answer = await ResearchSocketHTTPProber().get(
            port: 8080, path: "/v1/models", host: "x\r\nX-Injected: 1", origin: nil,
            authorization: nil, timeout: 1)
        #expect(answer == .noAnswer)
    }

    @Test func aStatusLineAndHeadersAreParsedWithLowerCaseNames() {
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Access-Control-Allow-Origin:  *  \r\nSet-Cookie: a=1\r\nset-cookie: b=2\r\n"
            + "\r\n{\"data\":[]}"
        let answer = ResearchHostHeaderRequest.parse(Array(reply.utf8))
        #expect(answer == .status(code: 200, headers: [
            "content-type": "application/json",
            "access-control-allow-origin": "*",
            "set-cookie": "a=1, b=2",
        ]))
    }

    @Test func aBareLineFeedAndAMissingReasonAreAccepted() {
        let answer = ResearchHostHeaderRequest.parse(Array("HTTP/1.0 421\nServer: x\n\n".utf8))
        #expect(answer == .status(code: 421, headers: ["server": "x"]))
    }

    @Test func garbageIsNoAnswer() {
        for text in ["", "hello", "HTTP/1.1", "HTTP/1.1 abc\r\n", "HTTP/1.1 20\r\n",
                     "HTTP/1.1 999\r\n", "HTTP/2 200\r\n", "SSH-2.0-OpenSSH_9.0\r\n",
                     "HTTP/1.1 200 OK"] {
            #expect(ResearchHostHeaderRequest.parse(Array(text.utf8)) == .noAnswer, "\(text)")
        }
        #expect(ResearchHostHeaderRequest.parse([0xff, 0xfe, 0x00, 0x0a]) == .noAnswer)
    }

    @Test func aLargeReplyStillGivesItsStatus() {
        let big = "HTTP/1.1 200 OK\r\nX-Pad: " + String(repeating: "a", count: 20_000)
            + "\r\n\r\n"
        let answer = ResearchHostHeaderRequest.parse(Array(big.utf8))
        #expect(answer.statusCode == 200)
    }

    @Test func theEndOfTheHeadersIsFound() {
        #expect(ResearchHostHeaderRequest.hasEndOfHeaders(Array("HTTP/1.1 200 OK\r\n\r\n".utf8)))
        #expect(ResearchHostHeaderRequest.hasEndOfHeaders(Array("HTTP/1.1 200 OK\n\n".utf8)))
        #expect(!ResearchHostHeaderRequest.hasEndOfHeaders(Array("HTTP/1.1 200 OK\r\nA: b\r\n".utf8)))
        #expect(!ResearchHostHeaderRequest.hasEndOfHeaders([]))
    }
}

// MARK: - A tiny HTTP server on 127.0.0.1, to try the real prober against

/// Listens on 127.0.0.1 and a port the system chose, answers each connection
/// in turn according to `mode` and closes it. `stop()` ends the thread and
/// closes the listening socket. Every wait has a time limit, so a test cannot
/// hang on it.
private final class FakeHTTPServer: @unchecked Sendable {
    enum Mode {
        /// 200 to any request.
        case answersEverything
        /// 403 unless the Host is 127.0.0.1:port or localhost:port.
        case checksHost
        /// 200 with `Access-Control-Allow-Origin: *`.
        case allowsAnyOrigin
        /// 401 unless the Authorization is the key; any Host.
        case requiresKey(String)
        /// Reads the request and closes the connection without a reply.
        case closesSilently
        /// Reads the request and says nothing for a while.
        case staysSilent
    }

    let port: Int
    private let descriptor: Int32
    private let mode: Mode
    private let lock = NSLock()
    private var stopping = false
    private var hosts: [String] = []
    private let finished = DispatchSemaphore(value: 0)

    init?(mode: Mode) {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let made = socket(AF_INET, streamType, 0)
        guard made >= 0 else { return nil }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(made, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(made, 8) == 0 else {
            close(made)
            return nil
        }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(made, generic, &length)
            }
        }
        let flags = fcntl(made, F_GETFL)
        guard result == 0, flags >= 0, fcntl(made, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close(made)
            return nil
        }
        descriptor = made
        port = Int(UInt16(bigEndian: named.sin_port))
        self.mode = mode
        DispatchQueue.global(qos: .userInitiated).async { self.serve() }
    }

    /// The Host values of the requests seen so far.
    var seenHosts: [String] { lock.withLock { hosts } }

    func stop() {
        lock.withLock { stopping = true }
        // The loop looks at the flag every 50 ms; a silent connection ends
        // within its own limit.
        _ = finished.wait(timeout: .now() + 10)
        close(descriptor)
    }

    private func serve() {
        defer { finished.signal() }
        while !lock.withLock({ stopping }) {
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 50) > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            #if canImport(Darwin)
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                           socklen_t(MemoryLayout<Int32>.size))
            #endif
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        // Read the request head: until the empty line, 16 KiB or 2 s.
        var request: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 2_048)
        let started = DispatchTime.now().uptimeNanoseconds
        while request.count < 16_384, !ResearchHostHeaderRequest.hasEndOfHeaders(request) {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            if elapsed >= 2_000 { break }
            var waiting = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(2_000 - elapsed))
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { break }
            let count = chunk.withUnsafeMutableBytes { raw in
                recv(client, raw.baseAddress, raw.count, 0)
            }
            if count > 0 {
                request.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                break
            }
        }
        let head = String(decoding: request, as: UTF8.self)
        var host = ""
        var authorization = ""
        for line in head.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            if lower.hasPrefix("host:") {
                host = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("authorization:") {
                authorization = String(text.dropFirst(14)).trimmingCharacters(in: .whitespaces)
            }
        }
        lock.withLock { hosts.append(host) }

        let reply: String?
        switch mode {
        case .answersEverything:
            reply = Self.response(200, extra: [])
        case .checksHost:
            let known = host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
            reply = known ? Self.response(200, extra: []) : Self.response(403, extra: [])
        case .allowsAnyOrigin:
            reply = Self.response(200, extra: ["Access-Control-Allow-Origin: *"])
        case .requiresKey(let key):
            reply = authorization == key
                ? Self.response(200, extra: []) : Self.response(401, extra: [])
        case .closesSilently:
            reply = nil
        case .staysSilent:
            Thread.sleep(forTimeInterval: 1.5)
            reply = nil
        }
        if let reply { Self.write(reply, to: client) }
    }

    private static func response(_ code: Int, extra: [String]) -> String {
        let body = "{\"data\":[]}"
        let reason = code == 200 ? "OK" : (code == 401 ? "Unauthorized" : "Forbidden")
        let lines = ["HTTP/1.1 \(code) \(reason)", "Content-Type: application/json",
                     "Content-Length: \(body.utf8.count)", "Connection: close"] + extra
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private static func write(_ text: String, to client: Int32) {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        let bytes = Array(text.utf8)
        var sent = 0
        var attempts = 0
        while sent < bytes.count, attempts < 200 {
            attempts += 1
            let wrote = bytes[sent...].withUnsafeBytes { raw in
                send(client, raw.baseAddress, raw.count, flags)
            }
            if wrote > 0 {
                sent += wrote
            } else if wrote < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(5_000)
            } else {
                return
            }
        }
    }
}

@Suite struct ResearchHostHeaderRealSocketTests {
    @Test func aServerThatAnswersEverythingAcceptsAnyHost() async throws {
        let server = try #require(FakeHTTPServer(mode: .answersEverything))
        defer { server.stop() }
        let report = await ResearchHostHeaderCheck.run(
            port: server.port, kind: .tuff, timeout: 3)
        #expect(report.verdict == .acceptsAnyHost)
        #expect(report.control.statusCode == 200)
        #expect(report.foreignHost?.statusCode == 200)
        #expect(!report.allowsForeignOrigin)
        #expect(report.warning != nil)
        // The server saw the host names that were meant.
        #expect(server.seenHosts.contains("127.0.0.1:\(server.port)"))
        #expect(server.seenHosts.contains("sandseek-host-check.invalid:\(server.port)"))
        let result = ResearchHostHeaderCommand.render(report: report)
        #expect(result.exitCode == 3)
    }

    @Test func aServerThatChecksTheHostIsRecognised() async throws {
        let server = try #require(FakeHTTPServer(mode: .checksHost))
        defer { server.stop() }
        let report = await ResearchHostHeaderCheck.run(
            port: server.port, kind: nil, timeout: 3)
        #expect(report.verdict == .checksHost)
        #expect(report.control.statusCode == 200)
        #expect(report.foreignHost?.statusCode == 403)
        #expect(report.warning == nil)
        #expect(ResearchHostHeaderCommand.render(report: report).exitCode == 0)
    }

    @Test func aServerWithOpenCorsIsNoted() async throws {
        let server = try #require(FakeHTTPServer(mode: .allowsAnyOrigin))
        defer { server.stop() }
        let report = await ResearchHostHeaderCheck.run(
            port: server.port, kind: .llamacpp, timeout: 3)
        #expect(report.verdict == .acceptsAnyHost)
        #expect(report.allowsForeignOrigin)
        #expect(report.corsNote != nil)
        if case .status(_, let headers)? = report.foreignOrigin {
            #expect(headers["access-control-allow-origin"] == "*")
        } else {
            Issue.record("expected an answer to the foreign origin probe")
        }
    }

    @Test func aKeyThatTheServerEnforcesProtectsTheRealServerToo() async throws {
        let server = try #require(FakeHTTPServer(mode: .requiresKey("Bearer s3cret")))
        defer { server.stop() }
        let report = await ResearchHostHeaderCheck.run(
            port: server.port, kind: .llamacpp, authorization: "Bearer s3cret", timeout: 3)
        #expect(report.verdict == .acceptsAnyHost)
        #expect(report.withoutKey?.statusCode == 401)
        #expect(report.protectedByKey)
        #expect(ResearchHostHeaderCommand.render(report: report).exitCode == 0)
        // Without a key the same server is reported as asking for one.
        let bare = await ResearchHostHeaderCheck.run(port: server.port, kind: nil, timeout: 3)
        #expect(bare.verdict == .keyRequired)
    }

    @Test func aClosedPortIsNoAnswer() async throws {
        let server = try #require(FakeHTTPServer(mode: .answersEverything))
        let port = server.port
        server.stop()
        let answer = await ResearchSocketHTTPProber().get(
            port: port, path: "/v1/models", host: "127.0.0.1:\(port)", origin: nil,
            authorization: nil, timeout: 2)
        #expect(answer == .noAnswer)
        let report = await ResearchHostHeaderCheck.run(port: port, kind: nil, timeout: 2)
        #expect(report.verdict == .serverNotRunning)
        #expect(ResearchHostHeaderCommand.render(report: report).exitCode == 4)
    }

    @Test func aConnectionClosedWithoutAReplyIsNoAnswer() async throws {
        let server = try #require(FakeHTTPServer(mode: .closesSilently))
        defer { server.stop() }
        let answer = await ResearchSocketHTTPProber().get(
            port: server.port, path: "/v1/models", host: "127.0.0.1:\(server.port)",
            origin: nil, authorization: nil, timeout: 3)
        #expect(answer == .noAnswer)
    }

    @Test func aServerThatSaysNothingEndsAtTheDeadline() async throws {
        let server = try #require(FakeHTTPServer(mode: .staysSilent))
        defer { server.stop() }
        let started = Date()
        let answer = await ResearchSocketHTTPProber().get(
            port: server.port, path: "/v1/models", host: "127.0.0.1:\(server.port)",
            origin: nil, authorization: nil, timeout: 0.5)
        #expect(answer == .noAnswer)
        #expect(Date().timeIntervalSince(started) < 1.4)
    }

    @Test func theRealProberReadsStatusAndLowerCaseHeaders() async throws {
        let server = try #require(FakeHTTPServer(mode: .allowsAnyOrigin))
        defer { server.stop() }
        let answer = await ResearchSocketHTTPProber().get(
            port: server.port, path: "/v1/models", host: "127.0.0.1:\(server.port)",
            origin: "http://sandseek-host-check.invalid:\(server.port)", authorization: nil,
            timeout: 3)
        guard case .status(let code, let headers) = answer else {
            Issue.record("expected an answer, got \(answer)")
            return
        }
        #expect(code == 200)
        #expect(headers["content-type"] == "application/json")
        #expect(headers["access-control-allow-origin"] == "*")
    }

    @Test func invalidPortsGiveNoAnswer() async {
        let prober = ResearchSocketHTTPProber()
        let zero = await prober.get(port: 0, path: "/v1/models", host: "h", origin: nil,
                                    authorization: nil, timeout: 1)
        let tooHigh = await prober.get(port: 70_000, path: "/v1/models", host: "h", origin: nil,
                                       authorization: nil, timeout: 1)
        #expect(zero == .noAnswer)
        #expect(tooHigh == .noAnswer)
    }
}

@Suite struct ResearchCheckHostHeaderArgumentTests {
    @Test func theOptionNeedsNoQuestionAndTakesTheServerOptions() throws {
        let parsed = try ResearchArguments.parse(["--check-host-header"], environment: [:])
        #expect(parsed.checkHostHeader)
        #expect(!parsed.checkExposure)
        #expect(parsed.question.isEmpty)
        let full = try ResearchArguments.parse(
            ["--check-host-header", "--server", "http://127.0.0.1:8081",
             "--server-type", "llamacpp", "--api-key-file", "/tmp/key", "--quiet"],
            environment: [:])
        #expect(full.checkHostHeader)
        #expect(full.serverURL.port == 8081)
        #expect(full.serverType == .llamacpp)
        #expect(full.apiKeyFile == "/tmp/key")
        #expect(full.quiet)
        let ollama = try ResearchArguments.parse(
            ["--check-host-header", "--server-type", "ollama"], environment: [:])
        #expect(ollama.serverURL.port == 11_434)
        let plain = try ResearchArguments.parse(["q"], environment: [:])
        #expect(!plain.checkHostHeader)
        #expect(ResearchArguments.usage.contains("--check-host-header"))
    }

    @Test func itDoesNotMixWithARunOrAnotherCheck() {
        for arguments in [["--check-host-header", "a question"],
                          ["--check-host-header", "--model", "x"],
                          ["--check-host-header", "--output", "/tmp/never"],
                          ["--check-host-header", "--sandbox", "http://127.0.0.1:9100"],
                          ["--check-host-header", "--stream", "off"],
                          ["--check-host-header", "--check-exposure"],
                          ["--check-exposure", "--check-host-header"],
                          ["--check-host-header", "--replay-figures", "/tmp/never.json"],
                          ["--check-host-header", "--server-type", "ollama",
                           "--api-key-file", "/tmp/key"]] {
            #expect(throws: ResearchArgumentError.self, "\(arguments)") {
                _ = try ResearchArguments.parse(arguments, environment: [:])
            }
        }
    }

    @Test func itRefusesAServerThatIsNotOnLoopback() {
        #expect(throws: (any Error).self) {
            _ = try ResearchArguments.parse(
                ["--check-host-header", "--server", "http://192.168.1.5:8080"], environment: [:])
        }
    }

    @Test func theExposureCheckStillRefusesTheServerTypeAndKeyOptions() {
        for arguments in [["--check-exposure", "--server-type", "llamacpp"],
                          ["--check-exposure", "--api-key-file", "/tmp/key"]] {
            #expect(throws: ResearchArgumentError.self, "\(arguments)") {
                _ = try ResearchArguments.parse(arguments, environment: [:])
            }
        }
    }
}
