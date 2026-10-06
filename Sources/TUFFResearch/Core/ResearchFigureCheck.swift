import Foundation

/// A figure in the answer that is not on any page its sentence cites.
public struct ResearchUnverifiedFigure: Equatable, Sendable {
    /// The figure as the answer wrote it, such as `4,74`.
    public let figure: String
    /// The source numbers the sentence cites, whose pages were checked.
    public let sources: [Int]

    public init(figure: String, sources: [Int]) {
        self.figure = figure
        self.sources = sources
    }
}

/// Checks the figures in an answer against the text of the pages it cites.
/// It is a hint only: a page can state a figure in words or in another unit.
/// Numbers are compared by their digits without trailing zeros, so `5,82`,
/// `5.82` and `582` match, `3.207.459` matches `3,207,459`, and `7,1 Mio`
/// matches `7,100,000`. A figure must equal a whole number on the page.
enum ResearchFigureCheck {
    struct Token: Equatable {
        /// The number as written, with its separators.
        let text: String
        /// The digits alone.
        let digits: String
        /// Years, dates, times, ordinals, single digits and names such as
        /// `H2O` are not figures to check.
        let ignored: Bool
    }

    /// The figures not found, in the order they appear, each once per
    /// sentence-and-sources. `sourceTexts` holds the page text read per
    /// source number; a sentence whose cited sources have no text is not
    /// checked.
    static func unverified(answer: String,
                           sourceTexts: [Int: String]) -> [ResearchUnverifiedFigure] {
        var haystacks: [Int: Set<String>] = [:]
        var found: [ResearchUnverifiedFigure] = []
        for piece in pieces(of: answer) {
            let cited = citations(in: piece)
            let usable = cited.filter { sourceTexts[$0] != nil }
            guard !usable.isEmpty else { continue }
            let figures = tokens(in: withoutNoise(piece)).filter { !$0.ignored }
            guard !figures.isEmpty else { continue }
            for number in usable where haystacks[number] == nil {
                haystacks[number] = haystack(of: sourceTexts[number] ?? "")
            }
            for figure in figures {
                let key = significant(figure.digits)
                if usable.contains(where: { haystacks[$0]?.contains(key) == true }) {
                    continue
                }
                let item = ResearchUnverifiedFigure(figure: figure.text, sources: usable)
                if !found.contains(item) { found.append(item) }
            }
        }
        return found
    }

    /// Every number in the text, as `significant` digits. Whole numbers
    /// only, so `47` does not match inside `2474`.
    static func haystack(of text: String) -> Set<String> {
        Set(tokens(in: text).map { significant($0.digits) })
    }

    /// The digits without trailing zeros, so a figure matches the same value
    /// written in another unit or with fewer decimals.
    static func significant(_ digits: String) -> String {
        var result = Substring(digits)
        while result.count > 1, result.last == "0" { result.removeLast() }
        return String(result)
    }

    /// Lines, and the sentences in them. A citation after the full stop
    /// (`… 5,8 %. [4]`) stays with the sentence it follows.
    static func pieces(of answer: String) -> [String] {
        var result: [String] = []
        for line in answer.split(whereSeparator: \.isNewline) {
            let characters = Array(line)
            var current = ""
            for (index, character) in characters.enumerated() {
                current.append(character)
                guard character == "." || character == "!" || character == "?",
                      index + 1 < characters.count, characters[index + 1].isWhitespace else {
                    continue
                }
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] != "[" {
                    result.append(current)
                    current = ""
                }
            }
            result.append(current)
        }
        return result
    }

    /// Source numbers cited in the text: `[4]`, `[6], [8]`, `[6][8]` and
    /// `[1, 2]`. A Markdown link is not a citation.
    static func citations(in text: String) -> [Int] {
        var numbers: [Int] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in citation.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            for part in text[range].split(whereSeparator: { !$0.isNumber }) {
                if let number = Int(part), !numbers.contains(number) { numbers.append(number) }
            }
        }
        return numbers
    }

    private static let citation = try! NSRegularExpression(
        pattern: #"\[(\d+(?:\s*[,;]\s*\d+)*)\](?!\()"#)
    private static let link = try! NSRegularExpression(
        pattern: #"(?:https?://|www\.)\S+"#)
    private static let isoDate = try! NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}"#)

    /// The text without citations, web addresses and ISO dates.
    static func withoutNoise(_ text: String) -> String {
        var result = text
        for expression in [citation, link, isoDate] {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        return result
    }

    /// Every number in the text. Thousands separators are `.`, `,`, `'` and
    /// spaces (a space only before exactly three digits), decimal separators
    /// are `.` and `,`.
    static func tokens(in text: String) -> [Token] {
        let characters = Array(text)
        var result: [Token] = []
        var index = 0
        while index < characters.count {
            guard isDigit(characters[index]) else { index += 1; continue }
            let start = index
            var digits = ""
            var group = 0
            var punctuated = false
            while index < characters.count {
                let character = characters[index]
                if isDigit(character) {
                    digits.append(character)
                    group += 1
                    index += 1
                    continue
                }
                if index + 1 < characters.count, isDigit(characters[index + 1]) {
                    if ".,'’".contains(character) {
                        punctuated = true
                        group = 0
                        index += 1
                        continue
                    }
                    if isSpace(character), !punctuated, group <= 3,
                       threeDigits(characters, from: index + 1) {
                        group = 0
                        index += 1
                        continue
                    }
                }
                break
            }
            let written = String(characters[start..<index])
            let following = index < characters.count ? characters[index] : " "
            let ignored = digits.count < 2
                || (start > 0 && characters[start - 1].isLetter)
                || isYear(written) || isDate(written, following: following)
                || (written.count <= 2 && following == ".")
                || isTime(characters, start: start, end: index)
            result.append(Token(text: written, digits: digits, ignored: ignored))
        }
        return result
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}" || character == "\u{2009}"
            || character == "\u{202F}"
    }

    private static func threeDigits(_ characters: [Character], from start: Int) -> Bool {
        guard start + 3 <= characters.count,
              characters[start..<start + 3].allSatisfy(isDigit) else { return false }
        return start + 3 == characters.count || !isDigit(characters[start + 3])
    }

    /// A four-digit year from 1900 to 2100 standing alone.
    private static func isYear(_ written: String) -> Bool {
        guard written.count == 4, let value = Int(written) else { return false }
        return (1900...2100).contains(value)
    }

    /// `5.2.2026`, `5.2.26`, and `5.2.` before its last dot.
    private static func isDate(_ written: String, following: Character) -> Bool {
        let parts = written.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) else { return false }
        if parts.count == 3 {
            return parts[0].count <= 2 && parts[1].count <= 2 && [2, 4].contains(parts[2].count)
        }
        return parts.count == 2 && parts[0].count <= 2 && parts[1].count <= 2 && following == "."
    }

    /// `12:30`: a number joined to another by a colon.
    private static func isTime(_ characters: [Character], start: Int, end: Int) -> Bool {
        let before = start >= 2 && characters[start - 1] == ":" && isDigit(characters[start - 2])
        let after = end + 1 < characters.count && characters[end] == ":"
            && isDigit(characters[end + 1])
        return before || after
    }
}
