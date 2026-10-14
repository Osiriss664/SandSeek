import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

/// Answers the listed paths with a redirect, as a program that took over the
/// port might, and everything else like the usual fake services.
private final class RedirectingServices: ResearchHTTPTransport, @unchecked Sendable {
    private let redirected: Set<String>
    private let everything: Bool
    private let inner: FakeResearchServices

    /// `everything` redirects every path.
    init(paths: Set<String> = [], everything: Bool = false,
         inner: FakeResearchServices = FakeResearchServices()) {
        redirected = paths
        self.everything = everything
        self.inner = inner
    }

    func send(method: String, url: URL, body: Data?) async throws -> ResearchHTTPResponse {
        if everything || redirected.contains(url.path) {
            return ResearchHTTPResponse(status: 307, body: Data())
        }
        return try await inner.send(method: method, url: url, body: body)
    }

    func send(method: String, url: URL, body: Data?, timeout: TimeInterval?,
              authorization: String?, headers: [String: String]) async throws -> ResearchHTTPResponse {
        if everything || redirected.contains(url.path) {
            return ResearchHTTPResponse(status: 307, body: Data())
        }
        return try await inner.send(method: method, url: url, body: body, timeout: timeout,
                                    authorization: authorization, headers: headers)
    }
}

@Suite @MainActor struct ResearchRedirectAppTests {
    private func problem(of server: ResearchServerController) -> String? {
        if case .problem(let message) = server.state { return message }
        return nil
    }

    @Test func aTuffAddressThatRedirectsIsAProblemNamedAsSuch() async {
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
            transport: RedirectingServices(everything: true))
        await server.check()
        let message = problem(of: server)
        #expect(message?.contains("redirect (HTTP 307)") == true)
        #expect(message?.contains("SandSeek refuses") == true)
        #expect(server.models.isEmpty)
    }

    @Test func aLlamaCppAddressThatRedirectsIsAProblemInEveryStep() async {
        // The status route, `/props` and `/v1/models`, one at a time.
        for path in ["/tuff/v1/status", "/props", "/v1/models"] {
            let services = RedirectingServices(
                paths: [path],
                inner: FakeResearchServices(tuffStatus: false, llamaContext: 8192))
            let server = ResearchServerController(
                defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
                transport: services)
            server.select(.llamacpp)
            await server.check()
            let message = problem(of: server)
            #expect(message?.contains("redirect (HTTP 307)") == true, "\(path)")
            #expect(server.state != .ready, "\(path)")
        }
    }

    @Test func aReadyServerWhoseHealthRouteStartsRedirectingIsLookedAtInFull() async {
        let services = FakeResearchServices(tuffStatus: false, llamaContext: 8192)
        let server = ResearchServerController(
            defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"), transport: services)
        server.select(.llamacpp)
        await server.check()
        #expect(server.state == .ready)

        let look = await ResearchServerController.quickLook(
            kind: .llamacpp, url: URL(string: "http://127.0.0.1:8081")!,
            transport: RedirectingServices(paths: ["/health"]))
        #expect(look == .changed)
        let tuffLook = await ResearchServerController.quickLook(
            kind: .tuff, url: URL(string: "http://127.0.0.1:8080")!,
            transport: RedirectingServices(everything: true))
        #expect(tuffLook == .changed)
    }

    @Test func aSandboxPortThatRedirectsIsNotARunningSandbox() async throws {
        let sandbox = ResearchSandboxController(
            runner: FakeProcessRunner(), transport: RedirectingServices(everything: true),
            defaults: MemorySettings(), environment: [:],
            resources: try testResources(), stateDirectory: temporaryDirectory(), secretFile: TestSandboxSecret.file)
        await sandbox.refresh()
        #expect(sandbox.state == .off)

        // A start whose VM comes up but whose port answers with a redirect
        // fails, and the message says what answered. Without the redirect
        // handling it said only that the sandbox does not answer.
        await sandbox.start()
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(message.contains("does not answer"))
        #expect(message.contains("redirect (HTTP 307)"))
        #expect(message.contains("SandSeek refuses"))
    }
}
