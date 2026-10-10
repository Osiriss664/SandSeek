import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

@Suite @MainActor struct ResearchReportImporterTests {
    private struct Folders {
        let tuff: URL
        let sandseek: URL
        let ledger: URL
    }

    private func folders() -> Folders {
        let root = temporaryDirectory("ImportTests")
        return Folders(
            tuff: root.appendingPathComponent("TUFF/Research Reports", isDirectory: true),
            sandseek: root.appendingPathComponent("SandSeek/Reports", isDirectory: true),
            ledger: root.appendingPathComponent("SandSeek/State/imported-report-ids.json"))
    }

    private func report(_ question: String, at seconds: Double) -> SavedResearchReport {
        SavedResearchReport(
            report: ResearchReport(
                question: question,
                answer: "Each container runs in its own VM [1].",
                sources: [ResearchSource(
                    number: 1, title: "apple/container", url: "https://github.com/apple/container")],
                modelTurns: 2, budgetExhausted: false, searchQueries: ["apple container"]),
            model: "gemma-4-e4b-it",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
            durationSeconds: 22,
            steps: [ResearchStep(id: 0, kind: .searching, text: "apple container", elapsed: 1)])
    }

    /// Reports as TUFF's research screen saved them: the same store code in
    /// the old folder.
    @discardableResult
    private func saveTUFFReports(_ count: Int, in folders: Folders) throws -> [SavedResearchReport] {
        let store = ResearchReportStore(directory: folders.tuff)
        let saved = (0..<count).map { report("Question \($0)", at: Double($0) * 100) }
        for report in saved { try store.save(report) }
        return saved
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return result
    }

    @Test func everyReportIsCopiedWithItsFilesUnchanged() throws {
        let folders = folders()
        let saved = try saveTUFFReports(3, in: folders)

        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome == .init(copied: 3, skipped: 0, unreadable: 0))

        let store = ResearchReportStore(directory: folders.sandseek)
        #expect(Set(store.reports.map(\.id)) == Set(saved.map(\.id)))
        // Same file names and the same bytes: the format is not changed.
        #expect(try snapshot(folders.sandseek) == snapshot(folders.tuff))
        #expect(store.reports.first { $0.id == saved[0].id }?.question == "Question 0")
        #expect(store.reports.first?.serverKind == nil)
    }

    @Test func theOriginalsAreNeverTouched() throws {
        let folders = folders()
        try saveTUFFReports(3, in: folders)
        let before = try snapshot(folders.tuff)
        let dates = try FileManager.default.contentsOfDirectory(atPath: folders.tuff.path).map {
            try FileManager.default.attributesOfItem(
                atPath: folders.tuff.appendingPathComponent($0).path)[.modificationDate] as? Date
        }

        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)

        #expect(try snapshot(folders.tuff) == before)
        let after = try FileManager.default.contentsOfDirectory(atPath: folders.tuff.path).map {
            try FileManager.default.attributesOfItem(
                atPath: folders.tuff.appendingPathComponent($0).path)[.modificationDate] as? Date
        }
        #expect(after == dates)
    }

    @Test func aSecondLaunchCopiesNothingAgain() throws {
        let folders = folders()
        try saveTUFFReports(2, in: folders)
        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        let first = try snapshot(folders.sandseek)

        let again = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(again == .init(copied: 0, skipped: 2, unreadable: 0))
        #expect(try snapshot(folders.sandseek) == first)
        #expect(ResearchReportStore(directory: folders.sandseek).reports.count == 2)
    }

    @Test func aReportDeletedInSandSeekDoesNotComeBack() throws {
        let folders = folders()
        let saved = try saveTUFFReports(2, in: folders)
        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)

        let store = ResearchReportStore(directory: folders.sandseek)
        for url in [store.jsonURL(for: saved[0]), store.markdownURL(for: saved[0])] {
            try FileManager.default.removeItem(at: url)
        }
        let again = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(again.copied == 0)
        #expect(ResearchReportStore(directory: folders.sandseek).reports.map(\.id) == [saved[1].id])
        // The original is still in TUFF's folder.
        #expect(FileManager.default.fileExists(
            atPath: ResearchReportStore(directory: folders.tuff).jsonURL(for: saved[0]).path))
    }

    @Test func reportsSavedLaterInTUFFAreTakenAtTheNextLaunch() throws {
        let folders = folders()
        try saveTUFFReports(1, in: folders)
        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        let later = report("Saved later", at: 5_000)
        try ResearchReportStore(directory: folders.tuff).save(later)

        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome == .init(copied: 1, skipped: 1, unreadable: 0))
        #expect(ResearchReportStore(directory: folders.sandseek).reports.count == 2)
    }

    @Test func aMissingTUFFFolderIsNothingToDo() {
        let folders = folders()
        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome == .init())
        #expect(!FileManager.default.fileExists(atPath: folders.sandseek.path))
        #expect(!FileManager.default.fileExists(atPath: folders.ledger.path))
    }

    @Test func filesThatAreNotReportsAreCountedAndLeftAlone() throws {
        let folders = folders()
        try saveTUFFReports(1, in: folders)
        let broken = folders.tuff.appendingPathComponent("broken.json")
        try Data("{not json".utf8).write(to: broken)
        try Data("note".utf8).write(to: folders.tuff.appendingPathComponent("readme.txt"))

        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome == .init(copied: 1, skipped: 0, unreadable: 1))
        #expect(try String(contentsOf: broken, encoding: .utf8) == "{not json")
        #expect(!FileManager.default.fileExists(
            atPath: folders.sandseek.appendingPathComponent("broken.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: folders.sandseek.appendingPathComponent("readme.txt").path))
    }

    @Test func oldReportsWithoutTheNewerFieldsAreTaken() throws {
        let folders = folders()
        let saved = try saveTUFFReports(1, in: folders)
        let url = ResearchReportStore(directory: folders.tuff).jsonURL(for: saved[0])
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["answerWasCutOff", "answerWasMidSentence", "savedSearchQueries",
                    "stoppedOnRepeats", "endedEarlyReason", "serverKind"] {
            object.removeValue(forKey: key)
        }
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome.copied == 1)
        let store = ResearchReportStore(directory: folders.sandseek)
        #expect(store.reports.map(\.id) == [saved[0].id])
        #expect(store.reports.first?.answerCutOff == false)
    }

    @Test func aReportWithoutItsMarkdownFileGetsOneMadeFromTheReport() throws {
        let folders = folders()
        let saved = try saveTUFFReports(1, in: folders)
        let tuffStore = ResearchReportStore(directory: folders.tuff)
        try FileManager.default.removeItem(at: tuffStore.markdownURL(for: saved[0]))

        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        let store = ResearchReportStore(directory: folders.sandseek)
        let markdown = try String(contentsOf: store.markdownURL(for: saved[0]), encoding: .utf8)
        #expect(markdown == saved[0].markdown)
        #expect(!FileManager.default.fileExists(atPath: tuffStore.markdownURL(for: saved[0]).path))
    }

    @Test func theSameReportTwiceInTUFFsFolderIsTakenOnce() throws {
        let folders = folders()
        let saved = try saveTUFFReports(1, in: folders)
        let source = ResearchReportStore(directory: folders.tuff).jsonURL(for: saved[0])
        let copy = folders.tuff.appendingPathComponent("copy of report.json")
        try FileManager.default.copyItem(at: source, to: copy)

        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome.copied == 1)
        #expect(outcome.skipped == 1)
        #expect(ResearchReportStore(directory: folders.sandseek).reports.count == 1)
    }

    @Test func aReportAlreadyInTheFolderIsNotOverwrittenAndIsRemembered() throws {
        let folders = folders()
        let saved = try saveTUFFReports(1, in: folders)
        // Put there by hand, with a different content under the same name.
        let target = ResearchReportStore(directory: folders.sandseek).jsonURL(for: saved[0])
        try FileManager.default.createDirectory(
            at: folders.sandseek, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: target)

        let outcome = ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        #expect(outcome.copied == 0)
        #expect(outcome.skipped == 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "mine")
        let ledger = try String(contentsOf: folders.ledger, encoding: .utf8)
        #expect(ledger.contains(saved[0].id.uuidString))
    }

    @Test func theLedgerHoldsIdsOnlyAndSitsOutsideTheReportsFolder() throws {
        let folders = folders()
        let saved = try saveTUFFReports(2, in: folders)
        ResearchReportImporter.importReports(
            from: folders.tuff, into: folders.sandseek, ledger: folders.ledger)
        let ledger = try String(contentsOf: folders.ledger, encoding: .utf8)
        for report in saved { #expect(ledger.contains(report.id.uuidString)) }
        #expect(!ledger.contains("Question"))
        let names = try FileManager.default.contentsOfDirectory(atPath: folders.sandseek.path)
        #expect(!names.contains { $0.contains("imported") })
    }

    @Test func theDefaultPathsAreTUFFsFolderAndSandSeeksLedger() {
        #expect(ResearchReportImporter.tuffReportsDirectory().path
            .hasSuffix("Application Support/TUFF/Research Reports"))
        #expect(ResearchReportImporter.defaultLedgerURL().path
            .hasSuffix("Application Support/SandSeek/State/imported-report-ids.json"))
    }

    @Test func theWorkspaceImportsOffTheMainThreadAndShowsTheReports() async throws {
        let folders = folders()
        try saveTUFFReports(3, in: folders)
        let reports = ResearchReportStore(directory: folders.sandseek)
        let workspace = ResearchWorkspace(
            sandbox: ResearchSandboxController(
                runner: FakeProcessRunner(), transport: FakeResearchServices(),
                defaults: MemorySettings(), environment: [:],
                resources: try testResources(), stateDirectory: temporaryDirectory()),
            server: ResearchServerController(
                defaults: MemorySettings(), keyStore: MemoryKeyStore(key: "k"),
                transport: FakeResearchServices()),
            reports: reports,
            run: ResearchRunController(store: reports, transport: FakeResearchServices()),
            presets: ResearchPresetStore(defaults: MemorySettings()))
        #expect(workspace.importedFromTUFF == nil)

        await workspace.importTUFFReports(from: folders.tuff, ledger: folders.ledger)
        #expect(workspace.importedFromTUFF == 3)
        #expect(workspace.reports.reports.count == 3)

        await workspace.importTUFFReports(from: folders.tuff, ledger: folders.ledger)
        #expect(workspace.importedFromTUFF == 0)
        #expect(workspace.reports.reports.count == 3)
    }
}
