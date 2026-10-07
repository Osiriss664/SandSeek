import Foundation

/// A figure or date in the answer that is not on any page its sentence cites.
public struct ResearchUnverifiedFigure: Equatable, Sendable {
    /// The figure as the answer wrote it, such as `4,74` or `29. November 2024`.
    public let figure: String
    /// The source numbers the sentence cites, whose pages were checked.
    public let sources: [Int]

    public init(figure: String, sources: [Int]) {
        self.figure = figure
        self.sources = sources
    }
}

/// Checks the figures and dates in an answer against the text of the pages it
/// cites.
/// It is a hint only: a page can state a figure in words or in another unit.
/// Numbers are compared by their digits without trailing zeros, so `5,82`,
/// `5.82` and `582` match, `3.207.459` matches `3,207,459`, and `7,1 Mio`
/// matches `7,100,000`. A figure must equal a whole number on the page.
/// A full date (`29.11.2024`, `29. November 2024`, `November 29, 2024`,
/// `2024-11-29`, German or English month names) matches the same day, month
/// and year in any of these forms; a month and year (`November 2024`) matches
/// the same month in any date or month-year form; a year (1900 to 2100) is
/// found as a year, in a date, or as any number on the page.
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

    /// The figures and dates not found, each once per sentence-and-sources:
    /// dates and months first, then the numbers and years in the order they
    /// appear. `sourceTexts` holds the page text read per source number; a
    /// sentence whose cited sources have no text is not checked.
    static func unverified(answer: String,
                           sourceTexts: [Int: String]) -> [ResearchUnverifiedFigure] {
        var pages: [Int: PageFacts] = [:]
        var found: [ResearchUnverifiedFigure] = []
        for piece in pieces(of: answer) {
            let cited = citations(in: piece)
            let usable = cited.filter { sourceTexts[$0] != nil }
            guard !usable.isEmpty else { continue }
            // The dates are taken out first, so their parts are not checked
            // again as separate numbers.
            let scanned = scan(withoutCitationsAndLinks(piece))
            var candidates: [Candidate] = []
            for mention in scanned.dates { candidates.append(.date(mention)) }
            for mention in scanned.monthYears { candidates.append(.monthYear(mention)) }
            for token in tokens(in: withoutNoise(scanned.remainder)) {
                if !token.ignored {
                    candidates.append(.number(token))
                } else if isYear(token.text) {
                    candidates.append(.year(token))
                }
            }
            guard !candidates.isEmpty else { continue }
            for number in usable where pages[number] == nil {
                pages[number] = PageFacts(sourceTexts[number] ?? "")
            }
            for candidate in candidates {
                let (figure, present) = candidate.check(in: usable.compactMap { pages[$0] })
                if present { continue }
                let item = ResearchUnverifiedFigure(figure: figure, sources: usable)
                if !found.contains(item) { found.append(item) }
            }
        }
        return found
    }

    /// A day, month and year, or a month and year when `day` is nil.
    struct Mention: Equatable {
        let day: Int?
        let month: Int
        let year: Int
        /// As written, such as `29. November 2024`.
        let text: String
    }

    private enum Candidate {
        case date(Mention)
        case monthYear(Mention)
        case year(Token)
        case number(Token)

        /// The figure as written, and whether any of the pages has it.
        func check(in pages: [PageFacts]) -> (String, Bool) {
            switch self {
            case .date(let mention):
                return (mention.text, pages.contains {
                    $0.dates.contains(DateKey(day: mention.day ?? 0, month: mention.month,
                                              year: mention.year))
                })
            case .monthYear(let mention):
                return (mention.text, pages.contains {
                    $0.monthYears.contains(MonthKey(month: mention.month, year: mention.year))
                })
            case .year(let token):
                let year = Int(token.digits) ?? 0
                return (token.text, pages.contains {
                    $0.years.contains(year) || $0.numbers.contains(ResearchFigureCheck.significant(token.digits))
                })
            case .number(let token):
                return (token.text, pages.contains {
                    $0.numbers.contains(ResearchFigureCheck.significant(token.digits))
                })
            }
        }
    }

    private struct DateKey: Hashable {
        let day: Int
        let month: Int
        let year: Int
    }

    private struct MonthKey: Hashable {
        let month: Int
        let year: Int
    }

    /// What a page has to match against: its numbers, dates, months and years.
    private struct PageFacts {
        let numbers: Set<String>
        var dates: Set<DateKey> = []
        var monthYears: Set<MonthKey> = []
        var years: Set<Int> = []

        init(_ text: String) {
            numbers = ResearchFigureCheck.haystack(of: text)
            let scanned = ResearchFigureCheck.scan(text)
            for mention in scanned.dates {
                dates.insert(DateKey(day: mention.day ?? 0, month: mention.month,
                                     year: mention.year))
                monthYears.insert(MonthKey(month: mention.month, year: mention.year))
                years.insert(mention.year)
            }
            for mention in scanned.monthYears {
                monthYears.insert(MonthKey(month: mention.month, year: mention.year))
                years.insert(mention.year)
            }
        }
    }

    /// Month names and short forms, German and English, lowercase without
    /// the closing dot.
    private static let months: [String: Int] = [
        "januar": 1, "january": 1, "jan": 1,
        "februar": 2, "february": 2, "feb": 2,
        "märz": 3, "maerz": 3, "march": 3, "mär": 3, "mar": 3,
        "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juni": 6, "june": 6, "jun": 6,
        "juli": 7, "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "oktober": 10, "october": 10, "okt": 10, "oct": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "december": 12, "dez": 12, "dec": 12,
    ]

    /// A date format: the regular expression and the group of each part
    /// (the month is a name unless `monthIsNumber`; a group of 0 is absent).
    private struct DateFormat {
        let regex: NSRegularExpression
        let day: Int
        let month: Int
        let year: Int
        let monthIsNumber: Bool
    }

    private static let monthNames: String = months.keys
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        .joined(separator: "|")
    /// A month name not inside a longer word, with an optional dot.
    private static let monthName = #"(?<!\p{L})(?:"# + monthNames + #")(?!\p{L})\.?"#

    /// Full dates first, then month and year, so `29. November 2024` is one
    /// date and not also `November 2024`.
    private static let dateFormats: [DateFormat] = [
        DateFormat(regex: expression(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#),
                   day: 3, month: 2, year: 1, monthIsNumber: true),
        DateFormat(regex: expression(#"(?<!\d)(\d{1,2})\.(\d{1,2})\.(\d{4})(?!\d)"#),
                   day: 1, month: 2, year: 3, monthIsNumber: true),
        DateFormat(regex: expression(
            #"(?<!\d)(\d{1,2})\.?\s+("# + monthName + #")\s*,?\s+(\d{4})(?!\d)"#),
                   day: 1, month: 2, year: 3, monthIsNumber: false),
        DateFormat(regex: expression(
            #"("# + monthName + #")\s+(\d{1,2})(?!\d)(?:st|nd|rd|th)?\s*,?\s+(\d{4})(?!\d)"#),
                   day: 2, month: 1, year: 3, monthIsNumber: false),
        DateFormat(regex: expression(#"("# + monthName + #")\s+(\d{4})(?!\d)"#),
                   day: 0, month: 1, year: 2, monthIsNumber: false),
    ]

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    struct Scan {
        /// Full dates, by position.
        var dates: [Mention] = []
        /// A month and year without a day, by position.
        var monthYears: [Mention] = []
        /// The text with every date and month-year replaced by `|`, so what
        /// is left can be read for numbers without the dates' parts.
        var remainder: String
    }

    /// The dates and month-years in the text, in `29.11.2024`,
    /// `29. November 2024`, `29 November 2024`, `November 29, 2024`,
    /// `2024-11-29` and `November 2024` form.
    static func scan(_ text: String) -> Scan {
        let working = NSMutableString(string: text)
        var dates: [(Int, Mention)] = []
        var monthYears: [(Int, Mention)] = []
        for format in dateFormats {
            let current = working.substring(from: 0)
            let whole = NSRange(current.startIndex..., in: current)
            for match in format.regex.matches(in: current, range: whole) {
                func group(_ index: Int) -> String? {
                    guard index > 0, let range = Range(match.range(at: index), in: current) else {
                        return nil
                    }
                    return String(current[range])
                }
                guard let year = group(format.year).flatMap({ Int($0) }),
                      let month = monthNumber(group(format.month), isNumber: format.monthIsNumber),
                      let written = Range(match.range, in: current).map({ String(current[$0]) })
                else { continue }
                let day = group(format.day).flatMap { Int($0) }
                if format.day > 0, !(day.map { (1...31).contains($0) } ?? false) { continue }
                let mention = Mention(day: day, month: month, year: year, text: written)
                if format.day > 0 {
                    dates.append((match.range.location, mention))
                } else {
                    monthYears.append((match.range.location, mention))
                }
                working.replaceCharacters(
                    in: match.range, with: String(repeating: "|", count: match.range.length))
            }
        }
        return Scan(dates: dates.sorted { $0.0 < $1.0 }.map(\.1),
                    monthYears: monthYears.sorted { $0.0 < $1.0 }.map(\.1),
                    remainder: working.substring(from: 0))
    }

    /// A month written as a number or as a name, from 1 to 12.
    private static func monthNumber(_ written: String?, isNumber: Bool) -> Int? {
        guard let written else { return nil }
        let month = isNumber
            ? Int(written)
            : months[written.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))]
        guard let month, (1...12).contains(month) else { return nil }
        return month
    }

    /// The text without citations and web addresses; ISO dates stay.
    private static func withoutCitationsAndLinks(_ text: String) -> String {
        var result = text
        for expression in [citation, link] {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        return result
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
                if next < characters.count, characters[next] != "[",
                   !isDayBeforeMonth(characters, dot: index, next: next) {
                    result.append(current)
                    current = ""
                }
            }
            result.append(current)
        }
        return result
    }

    /// The dot of a German day before a month name (`29. November`), which
    /// does not end the sentence.
    private static func isDayBeforeMonth(_ characters: [Character], dot: Int, next: Int) -> Bool {
        var start = dot
        while start > 0, isDigit(characters[start - 1]) { start -= 1 }
        guard (1...2).contains(dot - start),
              start == 0 || !isDigit(characters[start - 1]) else { return false }
        var end = next
        while end < characters.count, characters[end].isLetter { end += 1 }
        return months[String(characters[next..<end]).lowercased()] != nil
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
