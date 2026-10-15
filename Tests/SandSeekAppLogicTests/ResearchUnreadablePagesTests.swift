import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

@Suite struct ResearchUnreadablePagesTests {
    private func step(_ id: Int, _ kind: ResearchStep.Kind, _ text: String) -> ResearchStep {
        ResearchStep(id: id, kind: kind, text: text, elapsed: Double(id))
    }

    private func saved(steps: [ResearchStep] = [],
                       figures: [ResearchUnverifiedFigure] = []) -> SavedResearchReport {
        var report = ResearchReport(
            question: "Question?",
            answer: "The value is 280 [1].",
            sources: [ResearchSource(number: 1, title: "Page", url: "https://example.com/a")],
            modelTurns: 1,
            budgetExhausted: false,
            searchQueries: ["a", "b"])
        report.unverifiedFigures = figures
        return SavedResearchReport(
            report: report, model: "m", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 5, steps: steps)
    }

    @Test func failedReadsAreListedWithAddressAndReason() {
        let steps = [
            step(0, .turn, "Step 1 of 8"),
            step(1, .reading, "https://www.example.org/report"),
            step(2, .failed, "request to www.example.org failed: The read operation timed out"),
            step(3, .reading, "https://example.com/ok"),
            step(4, .reading, "https://example.com/other"),
            step(5, .failed, "the sandbox returned an unreadable page"),
            // The same failure twice is listed once.
            step(6, .reading, "https://example.com/other"),
            step(7, .failed, "the sandbox returned an unreadable page"),
        ]
        let pages = saved(steps: steps).unreadablePages
        #expect(pages == [
            UnreadablePage(address: "https://www.example.org/report",
                           reason: "request to www.example.org failed: The read operation timed out"),
            UnreadablePage(address: "https://example.com/other",
                           reason: "the sandbox returned an unreadable page"),
        ])
        #expect(pages[0].line == "https://www.example.org/report \u{2014} request to www.example.org failed: The read operation timed out")
    }

    @Test func otherFailuresAreNotFailedReads() {
        let steps = [
            step(0, .reading, "https://example.com/a"),
            step(1, .failed, "open_page: https://example.com/a redirected to https://example.com/b; not counted as a source"),
            step(2, .reading, "Repeated page refused: https://example.com/a"),
            step(3, .failed, "some error"),
            step(4, .searching, "query"),
            step(5, .failed, "search failed"),
            step(6, .reading, "https://example.com/c"),
            step(7, .failed, "Stopped."),
        ]
        #expect(saved(steps: steps).unreadablePages.isEmpty)
        #expect(saved().unreadablePages.isEmpty)
    }

    @Test func addressAndReasonAreCleaned() {
        let steps = [
            step(0, .reading, "https://example.com/\u{202E}a b\u{200B}c"),
            step(1, .failed, "bad\u{1B}[31m\nline\u{202E}"),
        ]
        let page = saved(steps: steps).unreadablePages.first
        #expect(page?.address == "https://example.com/abc")
        #expect(page?.reason == "bad[31m line")
    }

    @Test func markdownListsThePagesOnlyWhenThereAreSome() {
        let steps = [
            step(0, .reading, "https://example.com/a"),
            step(1, .failed, "timed out"),
        ]
        let with = saved(steps: steps).markdown
        #expect(with.contains("## Pages that could not be read"))
        #expect(with.contains("- https://example.com/a \u{2014} timed out"))
        #expect(!saved().markdown.contains("could not be read"))
    }

    @Test func figureCheckListIsSavedWithTheReportsWording() throws {
        let figures = [ResearchUnverifiedFigure(figure: "280", sources: [1])]
        let report = saved(figures: figures)
        #expect(report.figureCheckGroups.count == 1)
        #expect(report.figureCheckGroups[0].lines == ["280 \u{2014} not on [1]"])
        #expect(report.figureCheckMore == 0)
        #expect(report.markdown.contains("- 280 \u{2014} not on [1]"))
        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(SavedResearchReport.self, from: data)
        #expect(back.figureCheckGroups == report.figureCheckGroups)
        #expect(saved().figureCheckGroups.isEmpty)
    }

    @Test func figureCheckListCountsWhatTheLimitLeftOut() {
        let figures = (1...25).map { ResearchUnverifiedFigure(figure: "\($0)", sources: [1]) }
        let report = saved(figures: figures)
        #expect(report.figureCheckGroups.flatMap(\.lines).count == 20)
        #expect(report.figureCheckMore == 5)
        #expect(report.markdown.contains("- and 5 more"))
    }

    @Test func printTextHasBothListsBelowTheSummary() {
        let steps = [
            step(0, .reading, "https://example.com/a"),
            step(1, .failed, "timed out"),
        ]
        let figures = [ResearchUnverifiedFigure(figure: "280", sources: [1])]
        let text = ResearchReportPrintText.plainText(for: saved(steps: steps, figures: figures))
        #expect(text.contains("Figure check (1)"))
        #expect(text.contains("\u{2022} 280 \u{2014} not on [1]"))
        #expect(text.contains("Pages that could not be read"))
        #expect(text.contains("\u{2022} https://example.com/a \u{2014} timed out"))
        let plain = ResearchReportPrintText.plainText(for: saved())
        #expect(!plain.contains("Figure check"))
        #expect(!plain.contains("could not be read"))
    }
}
