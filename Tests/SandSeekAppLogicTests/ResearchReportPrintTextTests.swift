import AppKit
import Foundation
import Testing
@testable import SandSeekAppLogic
@testable import SandSeekCore

@Suite struct ResearchReportPrintTextTests {
    private func report(question: String = "How does Apple container isolate containers?",
                        answer: String = "Each container runs in its own **VM** [1]. See [docs](https://evil.example/x).")
        -> SavedResearchReport {
        SavedResearchReport(
            report: ResearchReport(
                question: question,
                answer: answer,
                sources: [
                    ResearchSource(number: 1, title: "apple/container",
                                   url: "https://github.com/apple/container"),
                    ResearchSource(number: 2, title: "",
                                   url: "https://example.com/a/long/path?q=1"),
                ],
                modelTurns: 2,
                budgetExhausted: false,
                searchQueries: ["apple container"]),
            model: "gemma-4-e4b-it",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 22,
            steps: [])
    }

    @Test func plainTextHoldsQuestionModelAnswerAndEverySource() {
        let text = ResearchReportPrintText.plainText(for: report())
        #expect(text.contains("How does Apple container isolate containers?"))
        #expect(text.contains("gemma-4-e4b-it"))
        #expect(text.contains("Each container runs in its own VM [1]."))
        #expect(text.contains("[1] apple/container"))
        #expect(text.contains("https://github.com/apple/container"))
        #expect(text.contains("[2] https://example.com/a/long/path?q=1"))
        // The model's own link is reduced to its words.
        #expect(text.contains("docs"))
        #expect(!text.contains("evil.example"))
    }

    @MainActor
    @Test func styledTextHasTheSameWordsAndNoLinks() {
        let styled = ResearchReportPrintText.attributed(for: report())
        #expect(styled.string == ResearchReportPrintText.plainText(for: report()))
        var linkCount = 0
        styled.enumerateAttribute(.link, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        #expect(linkCount == 0)
    }

    @MainActor
    @Test func citationNumbersStayPlainText() {
        let styled = ResearchReportPrintText.attributed(for: report(answer: "True [1, 2]."))
        #expect(styled.string.contains("True [1, 2]."))
        var linkCount = 0
        styled.enumerateAttribute(.link, in: NSRange(location: 0, length: styled.length)) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        #expect(linkCount == 0)
    }

    @Test func fileNameComesFromTheQuestionAndIsSafe() {
        #expect(ResearchReportPrintText.suggestedFileName(for: report())
            == "How does Apple container isolate containers?")
        #expect(ResearchReportPrintText.suggestedFileName(
            for: report(question: "a/b: c\\d\n e")) == "a b c d e")
        #expect(ResearchReportPrintText.suggestedFileName(for: report(question: " ../ ")) == "Research report")
        #expect(ResearchReportPrintText.suggestedFileName(
            for: report(question: String(repeating: "x", count: 200))).count <= 60)
    }

    @Test func warningsFromTheScreenAreInThePrintedText() {
        let base = ResearchReport(
            question: "q", answer: "Answer [7].",
            sources: [ResearchSource(number: 1, title: "t", url: "https://example.com/")],
            modelTurns: 1, budgetExhausted: true, searchQueries: ["one"])
        let saved = SavedResearchReport(
            report: base, model: "m", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            durationSeconds: 1, steps: [])
        let text = ResearchReportPrintText.plainText(for: saved)
        #expect(text.contains("The research ran out of steps, so this answer may be incomplete."))
        #expect(text.contains("Only one search was run"))
        for warning in saved.printedAnswerWarnings { #expect(text.contains(warning)) }
    }
}
