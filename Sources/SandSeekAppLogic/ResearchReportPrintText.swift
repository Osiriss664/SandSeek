import AppKit
import Foundation
import SandSeekCore

/// The text of a report as it is printed or exported to PDF: the question as
/// the title, the date and the model, the answer and the numbered sources with
/// their full addresses. Everything is plain text. A web address is written
/// out for a reader of the paper and is never a link, and neither is anything
/// in the answer.
public enum ResearchReportPrintText {
    /// The report as text without formatting.
    public static func plainText(for report: SavedResearchReport) -> String {
        sections(for: report).map(\.text).joined()
    }

    /// The report as styled text for a text view that prints. It holds no
    /// `.link` attribute anywhere.
    @MainActor
    public static func attributed(for report: SavedResearchReport) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for section in sections(for: report) {
            switch section.style {
            case .title:
                result.append(styled(section.text, font: .systemFont(ofSize: 20, weight: .bold),
                                     after: 6))
            case .meta:
                result.append(styled(section.text, font: .systemFont(ofSize: 10),
                                     color: .darkGray, after: 16))
            case .heading:
                result.append(styled(section.text, font: .systemFont(ofSize: 14, weight: .semibold),
                                     before: 10, after: 4))
            case .note:
                result.append(styled(section.text, font: .systemFont(ofSize: 10),
                                     color: .darkGray, after: 8))
            case .answer:
                result.append(answerText(for: report))
                result.append(styled("\n", font: .systemFont(ofSize: 11), after: 8))
            case .source:
                result.append(styled(section.text, font: .systemFont(ofSize: 10.5), after: 5,
                                     indent: 22))
            }
        }
        return result
    }

    /// A file name for the report without an extension, from the question:
    /// one line, no characters a file name cannot hold, at most 60 characters.
    public static func suggestedFileName(for report: SavedResearchReport) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters).union(.illegalCharacters)
        let cleaned = ResearchText.oneLine(report.question, limit: 60)
            .replacingOccurrences(of: "…", with: "")
            .unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ")
                .union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Research report" : cleaned
    }

    // MARK: - Building blocks

    enum Style { case title, meta, heading, note, answer, source }

    struct Section {
        let style: Style
        let text: String
    }

    /// The report in order, each part ending in its own line break.
    static func sections(for report: SavedResearchReport) -> [Section] {
        var parts: [Section] = []
        let question = ResearchText.terminalSafe(report.question)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(Section(style: .title, text: question + "\n"))

        var meta = report.createdAt.formatted(date: .long, time: .shortened)
        var model = ResearchText.oneLine(report.model, limit: 120)
        if let server = report.serverDisplayName { model += " on " + server }
        if !model.isEmpty { meta += " \u{00B7} " + model }
        parts.append(Section(style: .meta, text: meta + "\n"))

        if let reason = report.endedEarly {
            parts.append(Section(
                style: .note,
                text: "This research ended early: \(ResearchText.oneLine(reason, limit: 300)). It has no answer.\n"))
        }
        let answer = plainAnswer(report)
        if !answer.isEmpty {
            parts.append(Section(style: .answer, text: answer + "\n"))
        }
        let cautions = [report.emptyAnswerNotice].compactMap { $0 }
            + report.answerWarnings + [report.singleSearchNotice].compactMap { $0 }
        for caution in cautions {
            parts.append(Section(style: .note, text: "Note: " + caution + "\n"))
        }
        if !report.figureCheckGroups.isEmpty {
            parts.append(Section(style: .heading,
                                 text: "Figure check (\(report.unverifiedFigureCount))\n"))
            for group in report.figureCheckGroups {
                parts.append(Section(style: .note,
                                     text: ResearchText.oneLine(group.intro, limit: 400) + "\n"))
                for line in group.lines {
                    parts.append(Section(style: .source,
                                         text: "\u{2022} " + ResearchText.oneLine(line, limit: 400) + "\n"))
                }
            }
            if report.figureCheckMore > 0 {
                parts.append(Section(style: .source,
                                     text: "\u{2022} and \(report.figureCheckMore) more\n"))
            }
        }
        let unreadable = report.unreadablePages
        if !unreadable.isEmpty {
            parts.append(Section(style: .heading, text: "Pages that could not be read (\(unreadable.count))\n"))
            for page in unreadable {
                parts.append(Section(style: .source, text: "\u{2022} " + page.line + "\n"))
            }
        }
        if !report.sources.isEmpty {
            parts.append(Section(style: .heading, text: "Sources\n"))
            for source in report.sources {
                let title = ResearchText.oneLine(source.title, limit: 300)
                let address = ResearchText.url(source.url)
                let head = title.isEmpty ? address : title
                let body = title.isEmpty ? "" : "\n" + address
                parts.append(Section(style: .source,
                                     text: "[\(source.number)] " + head + body + "\n"))
            }
        }
        parts.append(Section(
            style: .note,
            text: "\nWritten from web pages by a local model. Check the sources before you rely on it.\n"))
        return parts
    }

    private static func plainAnswer(_ report: SavedResearchReport) -> String {
        ResearchAnswerFormatter.plainText(report.answer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer with bold, italics and code kept, citation numbers as plain
    /// text and no links of any kind.
    @MainActor
    private static func answerText(for report: SavedResearchReport) -> NSAttributedString {
        let formatted = ResearchAnswerFormatter.attributed(report.answer, sourceNumbers: [])
        let base = NSFont.systemFont(ofSize: 11)
        let manager = NSFontManager.shared
        let result = NSMutableAttributedString()
        var trimmed = formatted
        while let last = trimmed.characters.last, last.isWhitespace || last.isNewline {
            trimmed.characters.removeLast()
        }
        for run in trimmed.runs {
            let text = String(trimmed[run.range].characters)
            var font = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                }
                if intent.contains(.stronglyEmphasized) {
                    font = manager.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    font = manager.convert(font, toHaveTrait: .italicFontMask)
                }
            }
            result.append(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 3
        result.addAttribute(.paragraphStyle, value: style,
                            range: NSRange(location: 0, length: result.length))
        return result
    }

    @MainActor
    private static func styled(_ text: String, font: NSFont, color: NSColor = .black,
                               before: CGFloat = 0, after: CGFloat = 0,
                               indent: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = indent
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }
}
