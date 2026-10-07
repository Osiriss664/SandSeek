import Foundation

/// A figure, date or name in the answer that the pages it cites do not back up.
public struct ResearchUnverifiedFigure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A figure or date that is on none of the cited pages.
        case notOnPage
        /// A figure or date that is on a cited page, but not near any of the
        /// names the sentence gives it.
        case elsewhereOnPage
        /// A name (`Bund der Kommunist:innen`, `macOS Sequoia 26`) with a word
        /// on none of the cited pages, or, with no citation, on none of the
        /// pages read.
        case name
    }

    /// The figure, date or name as the answer wrote it, such as `4,74`,
    /// `29. November 2024` or `Bibliotheca Albertina`.
    public let figure: String
    /// The source numbers whose pages were checked: the cited ones, or for
    /// `elsewhereOnPage` those that have the figure. Empty for a name in a
    /// sentence without citations, which was checked against all pages read.
    public let sources: [Int]
    public let kind: Kind
    /// For `elsewhereOnPage`, the names of the sentence that are on the page
    /// but not next to the figure.
    public let names: [String]

    public init(figure: String, sources: [Int], kind: Kind = .notOnPage, names: [String] = []) {
        self.figure = figure
        self.sources = sources
        self.kind = kind
        self.names = names
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
/// A full date or a number that is on a cited page is also expected near
/// what the sentence names (see `unverified`), and the names in the answer
/// are looked up on the pages (see `phrases`).
enum ResearchFigureCheck {
    struct Token: Equatable {
        /// The number as written, with its separators.
        let text: String
        /// The digits alone.
        let digits: String
        /// Years, dates, times, ordinals, single digits and names such as
        /// `H2O` are not figures to check.
        let ignored: Bool
        /// Where it starts in the text, in UTF-16 units.
        let location: Int
    }

    /// The figures, dates and names not backed up, each once per
    /// sentence-and-sources: in each sentence the dates and months first,
    /// then the numbers and years in the order they appear, then the names.
    /// `sourceTexts` holds the page text read per source number.
    ///
    /// A figure not on any cited page is `notOnPage`. A full date or a number
    /// that is on a cited page, but never within `contextWindow` characters
    /// of a name the sentence has (a table's `Bibliothek Musik` next to the
    /// date where the answer says `Albertina`), is `elsewhereOnPage`. Only
    /// names that are on that page count; a name that is nowhere on it says
    /// nothing about where the figure stands. It is flagged only if every
    /// cited page that has the figure fails that test. Figures are only
    /// checked in sentences with a citation whose page was read.
    ///
    /// Names (see `phrases`) are checked in every sentence, against the
    /// cited pages, or against all pages read when the sentence cites none.
    /// `question` words are not flagged as names: the user wrote them.
    static func unverified(answer: String,
                           sourceTexts: [Int: String],
                           question: String = "") -> [ResearchUnverifiedFigure] {
        var pages: [Int: PageFacts] = [:]
        func facts(_ number: Int) -> PageFacts? {
            if let known = pages[number] { return known }
            guard let text = sourceTexts[number] else { return nil }
            let made = PageFacts(text)
            pages[number] = made
            return made
        }
        // One form of every accented letter, so words and offsets agree.
        let text = answer.precomposedStringWithCanonicalMapping
        let questionWords = WordIndex(question)
        let answerLanguage = language(text[...])
        var found: [ResearchUnverifiedFigure] = []
        func add(_ item: ResearchUnverifiedFigure) {
            let known = found.contains {
                $0.kind == item.kind
                    && (item.kind == .name
                        ? $0.figure.lowercased() == item.figure.lowercased()
                        : $0 == item)
            }
            if !known { found.append(item) }
        }
        for piece in pieces(of: text) {
            let cited = citations(in: piece)
            let usable = cited.filter { sourceTexts[$0] != nil }
            // A sentence that cites only pages that were not read has nothing
            // to be checked against.
            if !cited.isEmpty, usable.isEmpty { continue }
            // The dates are taken out first, so their parts are not checked
            // again as separate numbers, nor read as names.
            let scanned = scan(withoutCitationsAndLinks(piece))
            let sentenceWords = wordList(in: scanned.remainder)
            let checked: [(number: Int, page: PageFacts)] = usable.compactMap { number in
                facts(number).map { (number: number, page: $0) }
            }
            for item in figureFindings(scanned: scanned, words: sentenceWords, pages: checked) {
                add(item)
            }
            // Source lists and headings are lists of titles, not claims. A
            // link's label is a title as well.
            if skipsNameCheck(piece) { continue }
            var nameWords = sentenceWords
            if piece.contains("](") {
                let bare = markdownLink.stringByReplacingMatches(
                    in: piece, range: NSRange(piece.startIndex..., in: piece), withTemplate: " ")
                nameWords = wordList(in: scan(withoutCitationsAndLinks(bare)).remainder)
            }
            // Without a usable citation only the sure kind of name is
            // checked. The others (two nouns in a row) are checked only when
            // the answer and the page are in the same language: a German
            // answer from an English page names things in its own words.
            let named = phrases(in: nameWords).filter {
                $0.strong || (!usable.isEmpty && answerLanguage != 0)
            }
            if named.isEmpty { continue }
            let namePages = usable.isEmpty
                ? sourceTexts.keys.sorted().compactMap(facts) : checked.map { $0.page }
            // With no page read there is nothing to look the names up in.
            if namePages.isEmpty { continue }
            // The language only decides whether two nouns are checked; once
            // they are, any cited page that has them counts.
            for phrase in named {
                if !phrase.strong, !namePages.contains(where: { $0.language == answerLanguage }) {
                    continue
                }
                if isMissing(phrase, from: namePages, question: questionWords) {
                    add(ResearchUnverifiedFigure(figure: phrase.text, sources: usable, kind: .name))
                }
            }
        }
        return found
    }

    /// The figures and dates of one sentence that are not on the pages it
    /// cites, or not near what it names.
    private static func figureFindings(scanned: Scan, words: [Word],
                                       pages: [(number: Int, page: PageFacts)])
        -> [ResearchUnverifiedFigure] {
        guard !pages.isEmpty else { return [] }
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
        let names = contextNames(in: words)
        var result: [ResearchUnverifiedFigure] = []
        for candidate in candidates {
            let (figure, present) = candidate.check(in: pages.map { $0.page })
            if !present {
                result.append(ResearchUnverifiedFigure(figure: figure, sources: pages.map { $0.number }))
            } else if let elsewhere = elsewhereOnPage(candidate, figure: figure, names: names,
                                                      pages: pages) {
                result.append(elsewhere)
            }
        }
        return result
    }

    /// Characters before and after a figure in which a name of its sentence
    /// is expected.
    static let contextWindow = 300

    /// The finding for a figure that is on the cited pages that have it, but
    /// never near a name of the sentence that is also on that page.
    private static func elsewhereOnPage(_ candidate: Candidate, figure: String,
                                        names: [NameWord],
                                        pages: [(number: Int, page: PageFacts)])
        -> ResearchUnverifiedFigure? {
        guard candidate.isContextChecked, !names.isEmpty else { return nil }
        var failing: [Int] = []
        var missing: [String] = []
        for (number, page) in pages {
            let places = candidate.locations(in: page)
            if places.isEmpty { continue }
            let occurring = names.filter { page.words.hasShortExtension(of: $0.stem) }
            // A page with none of the sentence's names cannot tell.
            if occurring.isEmpty { return nil }
            for place in places {
                for name in occurring
                where page.has(name.stem, near: place, length: figure.utf16.count) {
                    return nil
                }
            }
            failing.append(number)
            for name in occurring where !missing.contains(name.text) { missing.append(name.text) }
        }
        guard !failing.isEmpty else { return nil }
        return ResearchUnverifiedFigure(figure: figure, sources: failing,
                                        kind: .elsewhereOnPage, names: Array(missing.prefix(3)))
    }

    /// A day, month and year, or a month and year when `day` is nil.
    struct Mention: Equatable {
        let day: Int?
        let month: Int
        let year: Int
        /// As written, such as `29. November 2024`.
        let text: String
        /// Where it starts in the text, in UTF-16 units.
        let location: Int
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

        /// Dates and numbers are expected near what the sentence names; a
        /// month or a year is too common on a page for that.
        var isContextChecked: Bool {
            switch self {
            case .date: return true
            // A short number matches by chance somewhere else on a page.
            case .number(let token): return ResearchFigureCheck.significant(token.digits).count >= 3
            case .monthYear, .year: return false
            }
        }

        /// Where the page has this date or number, in UTF-16 units.
        func locations(in page: PageFacts) -> [Int] {
            switch self {
            case .date(let mention):
                return page.dateLocations[DateKey(day: mention.day ?? 0, month: mention.month,
                                                  year: mention.year)] ?? []
            case .number(let token):
                return page.numberLocations[ResearchFigureCheck.significant(token.digits)] ?? []
            case .monthYear, .year:
                return []
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

    /// What a page has to match against: its numbers, dates, months, years
    /// and words. Each part is worked out when first asked for, so a page
    /// costs only what the answer needs from it.
    private final class PageFacts {
        let text: String

        init(_ text: String) { self.text = text.precomposedStringWithCanonicalMapping }

        private lazy var scanned: Scan = ResearchFigureCheck.scan(self.text)

        /// Every number on the page as `significant` digits, with where its
        /// tokens start.
        lazy var numberLocations: [String: [Int]] = {
            var result: [String: [Int]] = [:]
            for token in ResearchFigureCheck.tokens(in: self.text) {
                result[ResearchFigureCheck.significant(token.digits), default: []]
                    .append(token.location)
            }
            return result
        }()
        lazy var numbers: Set<String> = Set(self.numberLocations.keys)

        /// Every full date on the page, in any format, with where it starts.
        lazy var dateLocations: [DateKey: [Int]] = {
            var result: [DateKey: [Int]] = [:]
            for mention in self.scanned.dates {
                result[DateKey(day: mention.day ?? 0, month: mention.month, year: mention.year),
                       default: []].append(mention.location)
            }
            return result
        }()
        lazy var dates: Set<DateKey> = Set(self.dateLocations.keys)

        lazy var monthYears: Set<MonthKey> = {
            var result: Set<MonthKey> = []
            for mention in self.scanned.dates + self.scanned.monthYears {
                result.insert(MonthKey(month: mention.month, year: mention.year))
            }
            return result
        }()

        lazy var years: Set<Int> = {
            var result: Set<Int> = []
            for mention in self.scanned.dates + self.scanned.monthYears {
                result.insert(mention.year)
            }
            return result
        }()

        lazy var words: WordIndex = WordIndex(self.text)

        /// German (1), English (-1) or unclear (0), from the first 20,000
        /// characters.
        lazy var language: Int = ResearchFigureCheck.language(self.text.prefix(20_000))

        /// The text in lower case. A character whose lower case has another
        /// length stays as it is, so positions stay the same.
        private lazy var folded: [UInt16] = {
            var result: [UInt16] = []
            result.reserveCapacity(self.text.utf16.count)
            for character in self.text {
                let own = String(character)
                let lower = own.lowercased()
                result.append(contentsOf: lower.utf16.count == own.utf16.count ? lower.utf16 : own.utf16)
            }
            return result
        }()

        /// Whether the lowercase `stem` is within `contextWindow` characters
        /// before or after the figure that starts at `place`.
        func has(_ stem: String, near place: Int, length: Int) -> Bool {
            let low = max(0, place - ResearchFigureCheck.contextWindow)
            let high = min(folded.count, place + length + ResearchFigureCheck.contextWindow)
            return ResearchFigureCheck.occurs(Array(stem.utf16), in: folded, from: low, to: high)
        }
    }

    /// The distinct words of a text in lower case, sorted, to ask whether
    /// any word starts with a stem (by binary search) or contains it. Answers
    /// are kept, so a stem is looked up once per text.
    private final class WordIndex {
        private let words: [String]
        private var prefixKnown: [String: Bool] = [:]
        private var shortKnown: [String: Bool] = [:]
        private var containedKnown: [String: Bool] = [:]

        init(_ text: String) {
            var seen = Set<String>()
            var current = ""
            for character in text.precomposedStringWithCanonicalMapping {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else if !current.isEmpty {
                    seen.insert(current.lowercased())
                    current = ""
                }
            }
            if !current.isEmpty { seen.insert(current.lowercased()) }
            words = seen.sorted()
        }

        /// The position of the first word that is not before `prefix`.
        private func lowerBound(_ prefix: String) -> Int {
            var low = 0
            var high = words.count
            while low < high {
                let middle = (low + high) / 2
                if words[middle] < prefix { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// Whether a word starts with `prefix`.
        func has(prefix: String) -> Bool {
            if let known = prefixKnown[prefix] { return known }
            let position = lowerBound(prefix)
            let answer = position < words.count && words[position].hasPrefix(prefix)
            prefixKnown[prefix] = answer
            return answer
        }

        /// Whether a word is the stem and at most three letters more, so
        /// `Albertina` is not found in `Albertinakeller`.
        func hasShortExtension(of stem: String) -> Bool {
            if let known = shortKnown[stem] { return known }
            var position = lowerBound(stem)
            var answer = false
            while position < words.count, words[position].hasPrefix(stem) {
                if words[position].count <= stem.count + 3 {
                    answer = true
                    break
                }
                position += 1
            }
            shortKnown[stem] = answer
            return answer
        }

        /// Whether a word has `part` anywhere in it, as a compound has the
        /// words it is made of. Each part is scanned for once.
        func has(containing part: String) -> Bool {
            if let known = containedKnown[part] { return known }
            let answer = words.contains { $0.contains(part) }
            containedKnown[part] = answer
            return answer
        }
    }

    /// Whether `needle` is in `haystack` between the two positions.
    private static func occurs(_ needle: [UInt16], in haystack: [UInt16],
                                 from low: Int, to high: Int) -> Bool {
        guard let first = needle.first, high - low >= needle.count else { return false }
        var start = low
        while start <= high - needle.count {
            if haystack[start] == first {
                var offset = 1
                while offset < needle.count, haystack[start + offset] == needle[offset] {
                    offset += 1
                }
                if offset == needle.count { return true }
            }
            start += 1
        }
        return false
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
                let mention = Mention(day: day, month: month, year: year, text: written,
                                      location: match.range.location)
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

    // MARK: Names

    /// A word of a sentence, with what decides whether it is part of a name.
    private struct Word {
        /// As written, with `:innen` and `*innen` endings.
        let text: String
        /// Only blanks between it and the word before it, so both stand in
        /// one phrase and not on either side of a comma or a bracket.
        let joined: Bool
        /// A colon or a bar before it (a table cell, a label): a capital
        /// there starts a clause, as at the start of a sentence.
        let afterBreak: Bool
        /// Starts with a digit.
        let number: Bool
        let capitalized: Bool
        /// A capital after a lowercase letter, as in `macOS` and `iPhone`.
        let internalCapital: Bool
        /// Two letters or more, all capitals, as in `PP` and `USA`.
        let allCaps: Bool
        let letters: Int
    }

    /// A word of the sentence that is expected near a figure on the page.
    private struct NameWord {
        let text: String
        let stem: String
    }

    /// A name in a sentence, and the words of it to look up on the pages.
    private struct Phrase {
        let text: String
        let checked: [String]
        /// Sure to be a name: a word with an inner capital or an acronym
        /// followed by a number, and what follows it. The rest (two nouns in
        /// a row) may be ordinary words.
        let strong: Bool
    }

    /// The words of a sentence. Letters and digits make a word; `:innen` and
    /// `*innen` after a word belong to it (`Kommunist:innen`).
    private static func wordList(in text: String) -> [Word] {
        let characters = Array(text)
        var result: [Word] = []
        var separator = ""
        var index = 0
        while index < characters.count {
            guard characters[index].isLetter || characters[index].isNumber else {
                separator.append(characters[index])
                index += 1
                continue
            }
            let start = index
            while index < characters.count {
                if characters[index].isLetter || characters[index].isNumber {
                    index += 1
                } else if characters[index] == ":" || characters[index] == "*",
                          isInnen(characters, at: index + 1) {
                    index += 6
                } else {
                    break
                }
            }
            let written = String(characters[start..<index])
            var internalCapital = false
            var afterLowercase = false
            for character in written {
                if character.isUppercase, afterLowercase { internalCapital = true }
                afterLowercase = character.isLowercase
            }
            let letters = written.filter { $0.isLetter }.count
            let blanks = separator.allSatisfy { $0 == " " || $0 == "\u{00A0}" }
            result.append(Word(
                text: written,
                joined: !result.isEmpty && !separator.isEmpty && blanks,
                afterBreak: separator.contains(":") || separator.contains("|"),
                number: written.first?.isNumber ?? false,
                capitalized: written.first?.isUppercase ?? false,
                internalCapital: internalCapital,
                allCaps: letters >= 2 && written.allSatisfy { !$0.isLowercase },
                letters: letters))
            separator = ""
        }
        return result
    }

    /// Whether `innen` stands at `start`, as a whole word.
    private static func isInnen(_ characters: [Character], at start: Int) -> Bool {
        guard start + 5 <= characters.count,
              String(characters[start..<start + 5]).lowercased() == "innen" else { return false }
        return start + 5 == characters.count || !characters[start + 5].isLetter
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    /// Linking words that may stand between the capitalized words of a name.
    private static let linkingWords = ResearchFigureCheck.wordSet(
        "der des die von vom für und of the and de la")

    /// Words that are no names: German and English function words, the
    /// words of dates and units, and the nouns that point into a text
    /// (`Tabelle 2`), which a page need not have.
    private static let ignoredWords: Set<String> = {
        var result = ResearchFigureCheck.wordSet("""
            der die das den dem des ein eine einer einem einen eines und oder aber auch nicht \
            nur noch wie wenn dann als bei mit von vom zu zum zur aus nach vor für über unter \
            auf an am im in ist sind war waren wird werden wurde wurden hat haben hatte hatten \
            kann können soll sollen muss müssen dass sich es er sie wir ihr ihre ihren ihrer \
            ihrem ihres sein seine seinen seiner seinem seines dieser diese dieses diesem \
            diesen jede jeder jedes jedem jeden alle allen aller alles mehr viele vielen \
            weitere weiteren weiterer weiteres weiter laut seit bis durch gegen ohne um so da \
            hier dort ab bereits etwa rund ca siehe beim ins ans \
            the a an and or but not of in on at to for from with by as is are was were be \
            been has have had will would can could should may might this that these those it \
            its their there here also more most other another each all any some than then \
            which who what when where how about over under after before between into during \
            per via
            """)
        result.formUnion(ResearchFigureCheck.wordSet("""
            montag dienstag mittwoch donnerstag freitag samstag sonnabend sonntag monday \
            tuesday wednesday thursday friday saturday sunday
            """))
        result.formUnion(ResearchFigureCheck.wordSet("""
            prozent euro dollar millionen million milliarden billion mio mrd jahr jahre jahren \
            monat monate monaten tag tage tagen woche wochen uhr stunde stunden minuten \
            sekunden kilometer meter percent euros dollars years months days hours \
            eur usd chf gbp
            """))
        result.formUnion(ResearchFigureCheck.wordSet("""
            artikel kapitel seite seiten tabelle abbildung abschnitt absatz nummer nr version \
            platz rang figure table chapter page section article paragraph
            """))
        // Units and the like, which have capitals inside.
        result.formUnion(ResearchFigureCheck.wordSet("""
            kwh mwh gwh twh mah db dbm dba gib mib kib tib kb kn khz ph ml kj mbit gbit kbit \
            gmbh
            """))
        result.formUnion(ResearchFigureCheck.months.keys)
        return result
    }()

    private static let germanFunctionWords = wordSet("der die das und ist nicht mit von für auf ein eine")
    private static let englishFunctionWords = wordSet("the and is of to with for that on are was")

    /// German (1), English (-1) or unclear (0), by counting function words.
    /// Short texts, and texts with both languages, are unclear.
    static func language(_ text: Substring) -> Int {
        var german = 0
        var english = 0
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            let lowered = word.lowercased()
            if germanFunctionWords.contains(lowered) { german += 1 }
            if englishFunctionWords.contains(lowered) { english += 1 }
        }
        if german >= 3, german > english * 2 { return 1 }
        if english >= 3, english > german * 2 { return -1 }
        return 0
    }

    private static let sourceLine = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s*)?(?:\[\d+\]|\d+\.\s*\[)"#)
    private static let markdownLink = try! NSRegularExpression(
        pattern: #"\[([^\]]*)\]\([^)]*\)"#)

    /// Whether a line is a heading or a line of a source list, whose words
    /// are titles.
    private static func skipsNameCheck(_ piece: String) -> Bool {
        if piece.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return true }
        return sourceLine.firstMatch(
            in: piece, range: NSRange(piece.startIndex..., in: piece)) != nil
    }

    private static func isIgnored(_ word: String) -> Bool {
        ignoredWords.contains(word.lowercased())
    }

    /// A word without its gender ending (`:innen`, `*innen`, `innen`) and one
    /// plural or case ending (`en`, `er`, `es`, `e`, `s`, `n`) if at least
    /// four letters stay, in lower case, so `Kommunist:innen` and
    /// `Kommunisten` meet at `kommunist`.
    private static func wordStem(_ word: String) -> String {
        var stem = word.lowercased()
        for suffix in [":innen", "*innen", "innen"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        for ending in ["en", "er", "es", "e", "s", "n"]
        where stem.hasSuffix(ending) && stem.count - ending.count >= 4 {
            stem.removeLast(ending.count)
            break
        }
        return stem
    }

    /// The names of a sentence that a page is expected to have near a
    /// figure: capitalized words other than the first, acronyms and words
    /// with an inner capital, once each by stem. The sentence's first word is
    /// capitalized whatever it is.
    private static func contextNames(in words: [Word]) -> [NameWord] {
        let first = words.firstIndex { !$0.number }
        var result: [NameWord] = []
        for (index, word) in words.enumerated() where !word.number && !isIgnored(word.text) {
            guard (word.capitalized && index != first && word.letters >= 3)
                || word.allCaps || word.internalCapital else { continue }
            let stem = wordStem(word.text)
            if stem.count >= 2, !result.contains(where: { $0.stem == stem }) {
                result.append(NameWord(text: word.text, stem: stem))
            }
        }
        return result
    }

    /// The name phrases of a sentence: a word with an inner capital or
    /// directly followed by a number (`macOS`, `iPhone`, `Sequoia 26`), with
    /// the capitalized words after it; and two or more capitalized words in
    /// a row, with linking words allowed between them (`Bibliotheca
    /// Albertina`, `Bund der Kommunist:innen`). German capitalizes every
    /// noun, so a single capitalized word is no name, and none starts at the
    /// sentence's first word unless that word has an inner capital.
    private static func phrases(in words: [Word]) -> [Phrase] {
        let first = words.firstIndex { !$0.number }
        // The first word, and one after a colon or a bar, is capitalized
        // whatever it is.
        func atStart(_ index: Int) -> Bool { index == first || words[index].afterBreak }
        func member(_ index: Int) -> Bool {
            let word = words[index]
            guard !word.number, word.capitalized, !isIgnored(word.text),
                  word.letters >= 3 || word.allCaps else { return false }
            return !atStart(index) || word.internalCapital
        }
        func isPlainNumber(_ index: Int) -> Bool {
            words[index].joined && words[index].number && !isYear(words[index].text)
        }
        /// nil if no name starts here, else whether it is a strong one. A
        /// number after a word is no sign of a name when it is a year
        /// (`Ende 2025`), and with only a capital to go on (`Staffel 3`) the
        /// name is not strong.
        func startsName(_ index: Int) -> Bool? {
            let word = words[index]
            guard !word.number, !isIgnored(word.text), word.letters >= 2 else { return nil }
            if word.internalCapital { return true }
            guard word.capitalized, !atStart(index), index + 1 < words.count,
                  isPlainNumber(index + 1) else { return nil }
            return word.allCaps
        }
        func phrase(_ indices: [Int], through last: Int, strong: Bool) -> Phrase {
            Phrase(text: words[indices[0]...last].map { $0.text }.joined(separator: " "),
                   checked: indices.map { words[$0].text }, strong: strong)
        }
        var result: [Phrase] = []
        var index = 0
        while index < words.count {
            if let strong = startsName(index) {
                var indices = [index]
                while let last = indices.last, last + 1 < words.count, words[last + 1].joined,
                      member(last + 1) {
                    indices.append(last + 1)
                }
                var last = indices[indices.count - 1]
                if last + 1 < words.count, isPlainNumber(last + 1) { last += 1 }
                result.append(phrase(indices, through: last, strong: strong))
                index = last + 1
            } else if member(index) {
                var indices = [index]
                while let last = indices.last {
                    var next = last + 1
                    while next < words.count, words[next].joined,
                          linkingWords.contains(words[next].text) {
                        next += 1
                    }
                    guard next < words.count, words[next].joined, member(next) else { break }
                    indices.append(next)
                }
                if indices.count >= 2 {
                    let last = indices[indices.count - 1]
                    result.append(phrase(indices, through: last, strong: false))
                    index = last + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return result
    }

    /// Whether a word of the name is on none of the pages and not in the
    /// question. A word counts as on a page when a page word has its stem
    /// anywhere in it, so a German compound that contains the name matches.
    private static func isMissing(_ phrase: Phrase, from pages: [PageFacts],
                                  question: WordIndex) -> Bool {
        for word in phrase.checked {
            let stem = wordStem(word)
            if stem.count >= 2, !question.has(prefix: stem),
               !pages.contains(where: { $0.words.has(containing: stem) }) {
                return true
            }
        }
        return false
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
        // Where each character starts in UTF-16 units, as the regular
        // expressions and the page index count.
        var offsets: [Int] = []
        offsets.reserveCapacity(characters.count)
        var units = 0
        for character in characters {
            offsets.append(units)
            units += String(character).utf16.count
        }
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
            result.append(Token(text: written, digits: digits, ignored: ignored,
                                location: offsets[start]))
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
