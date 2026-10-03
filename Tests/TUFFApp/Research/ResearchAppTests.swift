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

    @Test func firstStartBuildsTheImageThenStarts() async throws {
        let root = try fakeCheckout()
        let runner = FakeProcessRunner()
        let services = FakeResearchServices()
        let settings = defaults()
        let controller = ResearchSandboxController(
            runner: runner, transport: services, defaults: settings,
            environment: [:], searchStart: [root])
        #expect(controller.repository != nil)

        await controller.start()
        #expect(controller.state == .ready)
        #expect(controller.startedByApp)
        #expect(runner.commands.map { $0.last } == ["build", "start"])

        // Unchanged files and an existing image: no rebuild.
        await controller.stop()
        #expect(controller.state == .off)
        await controller.start()
        #expect(runner.commands.map { $0.last } == [
            "build", "start", "stop", ResearchSandboxController.imageName, "start",
        ])

        // A changed sandbox file is rebuilt before the next start.
        await controller.stop()
        try Data("print('changed')\n".utf8).write(
            to: root.appendingPathComponent("Sandbox/web-research/server.py"))
        await controller.start()
        #expect(runner.commands.suffix(2).map { $0.last } == ["build", "start"])
    }

    @Test func reportsAMissingContainerTool() async throws {
        let runner = FakeProcessRunner { _ in
            ResearchProcessResult(
                status: 1,
                output: "Apple container is not installed; see https://github.com/apple/container\n")
        }
        let controller = ResearchSandboxController(
            runner: runner, transport: FakeResearchServices(sandboxHealthy: false),
            defaults: defaults(), environment: [:], searchStart: [try fakeCheckout()])
        await controller.start()
        guard case .failed(let message) = controller.state else {
            Issue.record("expected a failure, got \(controller.state)")
            return
        }
        #expect(message.contains("Apple container is not installed"))
        #expect(!controller.startedByApp)
    }

    @Test func withoutACheckoutItAsksForTheFolder() async {
        let controller = ResearchSandboxController(
            runner: FakeProcessRunner(), transport: FakeResearchServices(sandboxHealthy: false),
            defaults: defaults(), environment: [:], searchStart: [temporaryDirectory()])
        #expect(controller.repository == nil)
        await controller.start()
        guard case .failed(let message) = controller.state else {
            Issue.record("expected a failure, got \(controller.state)")
            return
        }
        #expect(message.contains("TUFF folder"))
    }

    @Test func refreshFollowsTheHealthCheck() async throws {
        let services = FakeResearchServices(sandboxHealthy: true)
        let controller = ResearchSandboxController(
            runner: FakeProcessRunner(), transport: services,
            defaults: defaults(), environment: [:], searchStart: [try fakeCheckout()])
        await controller.refresh()
        #expect(controller.state == .ready)
        services.setSandboxHealthy(false)
        await controller.refresh()
        #expect(controller.state == .off)
    }

    @Test func pathIncludesWhereContainerInstalls() {
        let environment = ResearchCommandEnvironment.environment(base: ["PATH": "/usr/bin:/bin"])
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(Set(path).count == path.count)
    }
}

@Suite @MainActor struct ResearchModelServerControllerTests {
    private func backgroundAPI() -> AppBackgroundAPIController {
        AppBackgroundAPIController(
            settingsURL: temporaryDirectory().appendingPathComponent("server.json"))
    }

    @Test func aServerStartedElsewhereIsUsedButNotStopped() async {
        let controller = ResearchModelServerController(
            backgroundAPI: backgroundAPI(),
            transport: FakeResearchServices(listedModels: ["gemma-4-e4b-it", "qwen-x"]),
            serverExecutable: nil, modelsRoot: nil,
            logURL: temporaryDirectory().appendingPathComponent("server.log"))
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
        let controller = ResearchModelServerController(
            backgroundAPI: backgroundAPI(),
            transport: FakeResearchServices(listedModels: nil),
            serverExecutable: nil, modelsRoot: nil,
            logURL: temporaryDirectory().appendingPathComponent("server.log"))
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
