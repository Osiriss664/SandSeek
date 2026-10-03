import Foundation
import TUFFResearchCore

/// Turns a research answer into text the app can show safely. The answer is
/// written by a model that read web pages, so it is shown as text only: links
/// the model wrote do nothing, images are never loaded, and the only active
/// parts are citation numbers, which point at the report's own source list.
public enum ResearchAnswerFormatter {
    public static let citationScheme = "tuff-research-source"

    public static func attributed(_ answer: String, sourceNumbers: Set<Int>) -> AttributedString {
        let clean = ResearchText.terminalSafe(answer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = AttributedString()
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            var line = String(rawLine)
            var isHeading = false
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= 6 {
                let rest = line.dropFirst(hashes)
                if rest.isEmpty || rest.first == " " {
                    line = rest.trimmingCharacters(in: .whitespaces)
                    isHeading = true
                }
            }
            var piece = inline(line)
            if isHeading {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(piece)
        }
        return linkCitations(in: result, sourceNumbers: sourceNumbers)
    }

    /// Bold, italics and code from one line of Markdown, with every link and
    /// image reference removed.
    static func inline(_ line: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var parsed = (try? AttributedString(markdown: line, options: options))
            ?? AttributedString(line)
        let ranges = parsed.runs.filter { $0.link != nil || $0.imageURL != nil }.map(\.range)
        for range in ranges {
            parsed[range].link = nil
            parsed[range].imageURL = nil
        }
        return parsed
    }

    /// Citation markers such as `[2]` or `[1, 3]` become links to the first
    /// source they name, when that source exists.
    static func linkCitations(in text: AttributedString,
                              sourceNumbers: Set<Int>) -> AttributedString {
        var text = text
        let plain = String(text.characters)
        let range = NSRange(plain.startIndex..., in: plain)
        var searchFrom = text.startIndex
        for match in citationPattern.matches(in: plain, range: range) {
            guard let matchRange = Range(match.range, in: plain),
                  let numbersRange = Range(match.range(at: 1), in: plain) else { continue }
            let numbers = plain[numbersRange].split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = numbers.first(where: sourceNumbers.contains),
                  let url = URL(string: "\(citationScheme)://\(first)"),
                  let found = text[searchFrom...].range(of: String(plain[matchRange]))
            else { continue }
            text[found].link = url
            searchFrom = found.upperBound
        }
        return text
    }

    /// The source number a citation link points at.
    public static func sourceNumber(from url: URL) -> Int? {
        guard url.scheme == citationScheme, let host = url.host else { return nil }
        return Int(host)
    }

    private static let citationPattern = try! NSRegularExpression(
        pattern: #"\[(\d+(?:\s*,\s*\d+)*)\](?!\()"#)
}
