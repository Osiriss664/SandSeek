import Darwin
import Foundation
import Testing
@testable import TUFFAppResearch
import TUFFAppServer
@testable import TUFFResearchCore

@Suite struct ResearchAnswerFormatterTests {
    private func links(in text: AttributedString) -> [URL] {
        text.runs.compactMap { $0.link }
    }

    @Test func linksTheModelWroteDoNothing() {
        let text = ResearchAnswerFormatter.attributed(
            "See [the docs](https://evil.example/?q=secret) and <https://other.example>. "
                + "![tracker](https://tracker.example/pixel.png)",
            sourceNumbers: [])
        #expect(links(in: text).isEmpty)
        #expect(!text.runs.contains { $0.imageURL != nil })
        #expect(String(text.characters).contains("the docs"))
    }

    @Test func citationsPointAtTheirSource() {
        let text = ResearchAnswerFormatter.attributed(
            "Each container gets its own VM [1]. Networking needs macOS 26 [2, 3]. Unknown [9].",
            sourceNumbers: [1, 2])
        let urls = links(in: text)
        #expect(urls.compactMap(ResearchAnswerFormatter.sourceNumber(from:)) == [1, 2])
        #expect(urls.allSatisfy { $0.scheme == ResearchAnswerFormatter.citationScheme })
        #expect(String(text.characters).contains("[9]"))
    }

    @Test func headingsLoseTheirMarkersAndControlCharactersAreRemoved() {
        let text = ResearchAnswerFormatter.attributed(
            "## Summary\nPlain \u{1B}[31mline\u{202E} [1]", sourceNumbers: [1])
        let plain = String(text.characters)
        #expect(plain.hasPrefix("Summary\n"))
        #expect(!plain.contains("\u{1B}"))
        #expect(!plain.contains("\u{202E}"))
    }

    @Test func onlyCitationLinksMapToSources() {
        #expect(ResearchAnswerFormatter.sourceNumber(
            from: URL(string: "tuff-research-source://4")!) == 4)
        #expect(ResearchAnswerFormatter.sourceNumber(from: URL(string: "https://4.example")!) == nil)
    }
}

@Suite struct ResearchSelfTestParsingTests {
    @Test func readsChecksSectionsAndSummary() {
        let output = """
        Fetches the sandbox must refuse:
          ok    http://192.168.64.1/ refused (blocked_address)
          FAIL  http://10.0.0.1/ was not refused: {"text": "\u{1B}]0;title"}
        The VM's own protection:
          ok    the firewall is loaded
        1 check(s) failed
        """
        let result = ResearchSelfTestResult.parse(output, status: 1)
        #expect(!result.passed)
        #expect(result.checks.map(\.outcome) == [.passed, .failed, .passed])
        #expect(result.checks.map(\.section) == [
            "Fetches the sandbox must refuse", "Fetches the sandbox must refuse",
            "The VM's own protection",
        ])
        #expect(result.checks[0].text == "http://192.168.64.1/ refused (blocked_address)")
        #expect(!result.checks[1].text.contains("\u{1B}"))
        #expect(result.summary == "1 check(s) failed")
    }

    @Test func passesOnlyWithChecksAndExitZero() {
        let good = ResearchSelfTestResult.parse(
            "A public page must still work:\n  ok    https://example.com/ fetched\nall sandbox checks passed\n",
            status: 0)
        #expect(good.passed)
        #expect(!ResearchSelfTestResult.parse("start the sandbox first", status: 1).passed)
        #expect(!ResearchSelfTestResult.parse("", status: 0).passed)
    }
}

@Suite @MainActor struct ResearchReportStoreTests {
    private func report(_ question: String = "How does Apple container isolate containers?")
        -> SavedResearchReport {
        SavedResearchReport(
            report: ResearchReport(
                question: question,
                answer: "Each container runs in its own VM [1].",
                sources: [ResearchSource(
                    number: 1, title: "apple/container", url: "https://github.com/apple/container")],
                modelTurns: 2,
                budgetExhausted: false),
            model: "gemma-4-e4b-it",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 22,
            steps: [ResearchStep(id: 0, kind: .searching, text: "apple container", elapsed: 1)])
    }

    @Test func savesJSONAndMarkdownAndReadsThemBack() throws {
        let directory = temporaryDirectory()
        let store = ResearchReportStore(directory: directory)
        #expect(store.reports.isEmpty)
        let saved = report()
        try store.save(saved)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files.count == 2)
        #expect(files.contains { $0.hasSuffix(".md") })
        #expect(files.contains { $0.hasSuffix(".json") })
        // Named from the date and id, never from the question.
        #expect(!files.contains { $0.contains("Apple") })
        let markdown = try String(contentsOf: store.markdownURL(for: saved), encoding: .utf8)
        #expect(markdown.hasPrefix("# How does Apple container isolate containers?"))

        let reloaded = ResearchReportStore(directory: directory)
        #expect(reloaded.reports.map(\.id) == [saved.id])
        #expect(reloaded.reports.first?.sources.first?.webURL?.host == "github.com")
        #expect(reloaded.reports.first?.steps.first?.kind == .searching)
    }

    @Test func neverWritesOverAnExistingReport() throws {
        let store = ResearchReportStore(directory: temporaryDirectory())
        let saved = report()
        try store.save(saved)
        #expect(throws: (any Error).self) { try store.save(saved) }
    }

    @Test func onlyWebAddressesCanBeOpened() {
        let source = { (url: String) in
            SavedResearchReport.Source(number: 1, title: "", url: url)
        }
        #expect(source("https://example.com/a").webURL != nil)
        #expect(source("http://example.com/").webURL != nil)
        #expect(source("file:///etc/passwd").webURL == nil)
        #expect(source("javascript:alert(1)").webURL == nil)
        #expect(source("x-apple.systempreferences:com.apple.preference").webURL == nil)
    }
}

@Suite @MainActor struct ResearchRunControllerTests {
    private let server = URL(string: "http://127.0.0.1:8080")!
    private let sandbox = URL(string: "http://127.0.0.1:9000")!

    @Test func runShowsProgressAndSavesTheReport() async throws {
        let services = FakeResearchServices(modelReplies: [
            FakeResearchServices.call("web_search", #"{"query": "apple container isolation"}"#),
            FakeResearchServices.call("open_page", #"{"url": "https://github.com/apple/container"}"#),
            FakeResearchServices.answer(
                "Each container runs in its own lightweight VM [1].",
                reasoning: "One source is enough here."),
        ])
        let store = ResearchReportStore(directory: temporaryDirectory())
        let run = ResearchRunController(store: store, transport: services)

        run.start(question: "  How are containers isolated?  ",
                  settings: ResearchRunSettings(model: "gemma-4-e4b-it", maxSteps: 4),
                  serverURL: server, sandboxURL: sandbox)
        #expect(run.isRunning)
        #expect(run.question == "How are containers isolated?")
        await waitUntil { !run.isRunning }

        #expect(run.phase == .finished)
        #expect(run.steps.map(\.kind) == [
            .turn, .searching, .turn, .reading, .turn, .thinking,
        ])
        #expect(run.steps.first?.text == "Step 1 of 4")
        #expect(run.steps.last?.text == "One source is enough here.")
        let report = try #require(run.report)
        #expect(report.sources.map(\.url) == ["https://github.com/apple/container"])
        #expect(report.model == "gemma-4-e4b-it")
        #expect(store.reports.map(\.id) == [report.id])
        #expect(run.saveError == nil)
    }

    @Test func aMissingSandboxEndsTheRunWithItsMessage() async {
        let services = FakeResearchServices(sandboxHealthy: false)
        let store = ResearchReportStore(directory: temporaryDirectory())
        let run = ResearchRunController(store: store, transport: services)
        run.start(question: "Anything", settings: ResearchRunSettings(model: "m"),
                  serverURL: server, sandboxURL: sandbox)
        await waitUntil { !run.isRunning }

        guard case .failed(let message) = run.phase else {
            Issue.record("expected a failure, got \(run.phase)")
            return
        }
        #expect(message.contains("sandbox"))
        #expect(store.reports.isEmpty)
        #expect(!services.paths.contains("/v1/chat/completions"))
    }

    @Test func stoppingDiscardsTheRun() async {
        let services = FakeResearchServices(modelReplies: [
            FakeResearchServices.answer("Too late."),
        ])
        let store = ResearchReportStore(directory: temporaryDirectory())
        let run = ResearchRunController(store: store, transport: services)
        run.start(question: "Anything", settings: ResearchRunSettings(model: "m"),
                  serverURL: server, sandboxURL: sandbox)
        run.stop()
        #expect(run.phase == .stopped)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(run.phase == .stopped)
        #expect(run.report == nil)
        #expect(store.reports.isEmpty)
    }

    @Test func emptyQuestionsDoNotStart() {
        let run = ResearchRunController(
            store: ResearchReportStore(directory: temporaryDirectory()),
            transport: FakeResearchServices())
        run.start(question: "   ", settings: ResearchRunSettings(model: "m"),
                  serverURL: server, sandboxURL: sandbox)
        #expect(run.phase == .idle)
    }

    @Test func thinkingRaisesTheTokenLimit() {
        #expect(ResearchRunSettings(model: "m", showThinking: true).maxTokens == 4_096)
        #expect(ResearchRunSettings(model: "m", showThinking: false).maxTokens == 1_024)
    }
}

@Suite @MainActor struct ResearchSandboxControllerTests {
    private func defaults() -> UserDefaults {
        let name = "TUFFResearchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func controller(runner: FakeProcessRunner = FakeProcessRunner(),
                            services: FakeResearchServices = FakeResearchServices(),
                            checkout: URL? = nil,
                            stateDirectory: URL = temporaryDirectory()) throws
        -> ResearchSandboxController {
        ResearchSandboxController(
            runner: runner, transport: services, defaults: defaults(),
            environment: [:], searchStart: [try checkout ?? fakeCheckout()],
            stateDirectory: stateDirectory)
    }

    @Test func findsTheCheckoutAboveABuildFolder() throws {
        let root = try fakeCheckout()
        let build = root.appendingPathComponent(".build/arm64-apple-macosx/release", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let found = ResearchSandboxController.findRepository(
            startingAt: build, fileExists: FileManager.default.fileExists(atPath:))
        #expect(found?.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(ResearchSandboxController.findRepository(
            startingAt: temporaryDirectory(), fileExists: { _ in false }) == nil)
    }

    @Test func firstStartBuildsTheImageThenStartsAndChecksProtection() async throws {
        let root = try fakeCheckout()
        let runner = FakeProcessRunner()
        let sandbox = try controller(runner: runner, checkout: root)
        #expect(sandbox.repository != nil)

        await sandbox.start()
        #expect(sandbox.state == .ready)
        #expect(sandbox.protection == .verified)
        #expect(sandbox.startedByApp)
        #expect(runner.scriptCommands == ["build", "start"])
        #expect(runner.commands.contains {
            $0.starts(with: ["env", "container", "exec", "tuff-web-research", "nft"])
        })

        // Unchanged files and an existing image: no rebuild.
        await sandbox.stop()
        #expect(sandbox.state == .off)
        #expect(sandbox.protection == .unknown)
        await sandbox.start()
        #expect(runner.scriptCommands == ["build", "start", "stop", "start"])
        #expect(runner.commands.contains { $0.last == ResearchSandboxController.imageName })

        // A changed sandbox file is rebuilt before the next start.
        await sandbox.stop()
        try Data("print('changed')\n".utf8).write(
            to: root.appendingPathComponent("Sandbox/web-research/server.py"))
        await sandbox.start()
        #expect(runner.scriptCommands.suffix(2) == ["build", "start"])
    }

    @Test func aSandboxWithoutItsFirewallIsNotVerified() async throws {
        let runner = FakeProcessRunner { command in
            command.contains("nft")
                ? ResearchProcessResult(status: 1, output: "Error: No such file or directory")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(runner: runner)
        await sandbox.start()
        #expect(sandbox.state == .ready)
        guard case .notVerified(let message) = sandbox.protection else {
            Issue.record("expected not verified, got \(sandbox.protection)")
            return
        }
        #expect(message.contains("firewall"))
    }

    @Test func readsTheFirewallListing() {
        let good = FakeProcessRunner.firewallListing
        #expect(ResearchSandboxController.firewallProblem(good) == nil)
        // nft may print service names, and SearXNG gets an IPv6 exception.
        #expect(ResearchSandboxController.firewallProblem(good
            .replacingOccurrences(of: "udp dport 53", with: "udp dport domain")
            .replacingOccurrences(of: "\t\toifname", with: "\t\tip6 daddr fd00::5 tcp dport ddi-tcp-1 accept\n\t\toifname")) == nil)
        let reject = "\t\treject\n\t}"

        let problems = [
            good.replacingOccurrences(of: "policy drop", with: "policy accept"),
            good.replacingOccurrences(of: "192.168.0.0/16", with: "192.168.1.0/24"),
            good.replacingOccurrences(of: "\t\toifname", with: "\t\tip daddr 192.168.0.0/16 accept\n\t\toifname"),
            good.replacingOccurrences(of: "\t\toifname", with: "\t\taccept\n\t\toifname"),
            good.replacingOccurrences(of: "\t\toifname", with: "\t\tjump other\n\t\toifname"),
            // The Mac, which is the DNS server, opened on another port.
            good.replacingOccurrences(of: "\t\toifname", with: "\t\tip daddr 192.168.64.1 tcp dport 22 accept\n\t\toifname"),
            // Two addresses besides DNS.
            good.replacingOccurrences(of: "\t\toifname", with: "\t\tip daddr 10.0.0.5 tcp dport 8888 accept\n\t\tip daddr 10.0.0.6 tcp dport 8888 accept\n\t\toifname"),
            // Anything allowed after the refusals, or handed elsewhere.
            good.replacingOccurrences(of: reject, with: "\t\tip6 daddr fe80::/10 accept\n" + reject),
            good.replacingOccurrences(of: reject, with: "\t\tqueue num 1\n" + reject),
            good.replacingOccurrences(of: "ip daddr @private4 reject", with: "ip daddr != @private4 reject"),
            "",
        ]
        for listing in problems {
            #expect(ResearchSandboxController.firewallProblem(listing) != nil)
        }
    }

    @Test func aPermissiveFirewallIsNotVerified() async throws {
        let runner = FakeProcessRunner { command in
            command.contains("nft")
                ? ResearchProcessResult(status: 0, output: FakeProcessRunner.firewallListing
                    .replacingOccurrences(of: "policy drop", with: "policy accept"))
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(runner: runner)
        await sandbox.start()
        guard case .notVerified(let message) = sandbox.protection else {
            Issue.record("expected not verified, got \(sandbox.protection)")
            return
        }
        #expect(message.contains("does not drop outbound traffic"))
    }

    @Test func protectionIsCheckedAgainBeforeEachQuestion() async throws {
        let firewallGone = LockedFlag()
        let runner = FakeProcessRunner { command in
            command.contains("nft") && firewallGone.value
                ? ResearchProcessResult(status: 1, output: "Error: No such file or directory")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(runner: runner)
        await sandbox.start()
        #expect(sandbox.protection == .verified)
        let checks = runner.commands.filter { $0.contains("nft") }.count

        await sandbox.recheckProtection()
        #expect(sandbox.protection == .verified)
        #expect(runner.commands.filter { $0.contains("nft") }.count == checks + 1)

        firewallGone.value = true
        await sandbox.recheckProtection()
        guard case .notVerified = sandbox.protection else {
            Issue.record("expected not verified, got \(sandbox.protection)")
            return
        }
    }

    @Test func aPrivilegedServerIsNotVerified() async throws {
        let runner = FakeProcessRunner { command in
            command.contains("python3")
                ? ResearchProcessResult(status: 0, output: "0 CapPrm,CapEff\n")
                : FakeProcessRunner.healthy(command)
        }
        let sandbox = try controller(runner: runner)
        await sandbox.start()
        guard case .notVerified(let message) = sandbox.protection else {
            Issue.record("expected not verified, got \(sandbox.protection)")
            return
        }
        #expect(message.contains("0 CapPrm,CapEff"))
    }

    @Test func aSandboxAlreadyAnsweringIsCheckedBeforeUse() async throws {
        let services = FakeResearchServices(sandboxHealthy: true)
        let sandbox = try controller(services: services)
        await sandbox.refresh()
        #expect(sandbox.state == .ready)
        #expect(sandbox.protection == .verified)
        services.setSandboxHealthy(false)
        await sandbox.refresh()
        #expect(sandbox.state == .off)
        #expect(sandbox.protection == .unknown)
    }

    @Test func aSandboxLeftFromACrashIsAdoptedAndStoppedAtQuit() async throws {
        let state = temporaryDirectory()
        let checkout = try fakeCheckout()
        let first = try controller(checkout: checkout, stateDirectory: state)
        await first.start()
        #expect(first.startedByApp)

        // The app "crashed": a new controller finds the marker.
        let services = FakeResearchServices(sandboxHealthy: true)
        let second = try controller(services: services, checkout: checkout, stateDirectory: state)
        #expect(second.startedByApp)
        #expect(second.adoptedFromLastRun)
        await second.refresh()
        #expect(second.state == .ready)

        // If the VM is gone, the marker is dropped.
        let third = try controller(
            services: FakeResearchServices(sandboxHealthy: false),
            checkout: checkout, stateDirectory: state)
        await third.refresh()
        #expect(!third.startedByApp)
        #expect(!third.adoptedFromLastRun)
        let fourth = try controller(checkout: checkout, stateDirectory: state)
        #expect(!fourth.startedByApp)
    }

    @Test func reportsAMissingContainerTool() async throws {
        let runner = FakeProcessRunner { _ in
            ResearchProcessResult(
                status: 1,
                output: "Apple container is not installed; see https://github.com/apple/container\n")
        }
        let sandbox = try controller(
            runner: runner, services: FakeResearchServices(sandboxHealthy: false))
        await sandbox.start()
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(message.contains("Apple container is not installed"))
        #expect(!sandbox.startedByApp)
    }

    @Test func withoutACheckoutItAsksForTheFolder() async {
        let sandbox = ResearchSandboxController(
            runner: FakeProcessRunner(), transport: FakeResearchServices(sandboxHealthy: false),
            defaults: defaults(), environment: [:], searchStart: [temporaryDirectory()],
            stateDirectory: temporaryDirectory())
        #expect(sandbox.repository == nil)
        await sandbox.start()
        guard case .failed(let message) = sandbox.state else {
            Issue.record("expected a failure, got \(sandbox.state)")
            return
        }
        #expect(message.contains("TUFF folder"))
    }

    @Test func pathIncludesWhereContainerInstalls() {
        let environment = ResearchCommandEnvironment.environment(base: ["PATH": "/usr/bin:/bin"])
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(Set(path).count == path.count)
    }

    @Test func aHungCommandIsEnded() async throws {
        let started = ContinuousClock.now
        let result = try await FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: [:], timeout: 0.5)
        #expect(result.status != 0)
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

@Suite @MainActor struct ResearchModelServerControllerTests {
    private func server(listedModels: [String]?,
                        stateDirectory: URL = temporaryDirectory(),
                        processName: @escaping (pid_t) -> String? = { _ in nil })
        -> ResearchModelServerController {
        ResearchModelServerController(
            backgroundAPI: backgroundAPI(),
            transport: FakeResearchServices(listedModels: listedModels),
            serverExecutable: nil, modelsRoot: nil,
            logURL: temporaryDirectory().appendingPathComponent("server.log"),
            stateDirectory: stateDirectory,
            processName: processName)
    }

    @Test func aServerLeftFromACrashIsTakenOver() async throws {
        let state = temporaryDirectory()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("4242".utf8).write(to: state.appendingPathComponent("server.pid"))
        let controller = server(listedModels: ["gemma-4-e4b-it"], stateDirectory: state,
                                processName: { $0 == 4242 ? "TUFFServer" : nil })
        #expect(controller.adoptedFromLastRun)
        await controller.refresh()
        #expect(controller.owner == .app)
    }

    @Test func aMarkerNamingAnotherProgramIsIgnored() throws {
        let state = temporaryDirectory()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let marker = state.appendingPathComponent("server.pid")
        try Data("4242".utf8).write(to: marker)
        let controller = server(listedModels: nil, stateDirectory: state,
                                processName: { _ in "Safari" })
        #expect(!controller.adoptedFromLastRun)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func readsTheNameOfARunningProcess() {
        #expect(ResearchModelServerController.processName(getpid()) != nil)
        #expect(ResearchModelServerController.processName(999_999) == nil)
    }

    private func backgroundAPI() -> AppBackgroundAPIController {
        AppBackgroundAPIController(
            settingsURL: temporaryDirectory().appendingPathComponent("server.json"))
    }

    @Test func aServerStartedElsewhereIsUsedButNotStopped() async {
        let controller = server(listedModels: ["gemma-4-e4b-it", "qwen-x"])
        await controller.refresh()
        #expect(controller.state == .ready)
        #expect(controller.owner == .outside)
        #expect(controller.models.map(\.id) == ["gemma-4-e4b-it", "qwen-x"])
        #expect(controller.models.first?.displayName != "gemma-4-e4b-it")

        await controller.stop()
        guard case .failed(let message) = controller.state else {
            Issue.record("expected an explanation, got \(controller.state)")
            return
        }
        #expect(message.contains("outside TUFF"))
    }

    @Test func withNoServerToStartItSaysHowToBuildOne() async {
        let controller = server(listedModels: nil)
        #expect(!controller.canStart)
        await controller.refresh()
        #expect(controller.state == .off)
        await controller.start()
        guard case .failed(let message) = controller.state else {
            Issue.record("expected a failure, got \(controller.state)")
            return
        }
        #expect(message.contains("swift build"))
    }

    @Test func findsTheServerBuiltBesideTheApp() {
        let found = ResearchModelServerController.findServerExecutable(
            bundle: .main, isExecutable: { $0.hasSuffix("/TUFFServer") })
        #expect(found?.lastPathComponent == "TUFFServer")
        #expect(ResearchModelServerController.findServerExecutable(
            bundle: .main, isExecutable: { _ in false }) == nil)
    }
}
