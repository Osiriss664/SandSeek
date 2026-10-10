import Foundation

/// A number of sources a question asks for.
struct ResearchSourceRequest: Equatable, Sendable {
    /// Sources the question wants at least.
    let minimum: Int
    /// Sources it allows at most, when it says so.
    let maximum: Int?
}

/// Reads the number of sources a question asks for: `mindestens 10 Quellen`,
/// `at least 10 sources`, `10–15 Quellen`, `minimum 30 max 40 Quellen`,
/// `30 Quellen`. A number with a cap only (`maximal 5 Quellen`, `up to 5
/// sources`) asks for no minimum, and a number that counts something else
/// (`die letzten 30 Jahre`, `30 Jahre alte Quellen`) is no source count.
enum ResearchSourceCount {
    /// A request below 2 asks for nothing the loop does anyway; above 100 it
    /// cannot be met.
    static let allowed = 2...100

    static func requested(in question: String) -> ResearchSourceRequest? {
        let text = question.precomposedStringWithCanonicalMapping
        var best: (location: Int, request: ResearchSourceRequest)?
        func consider(_ location: Int, _ minimum: Int, _ maximum: Int?) {
            guard allowed.contains(minimum), maximum.map({ $0 >= minimum }) ?? true else { return }
            if best == nil || location < best!.location {
                best = (location, ResearchSourceRequest(minimum: minimum, maximum: maximum))
            }
        }
        let whole = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        /// Whether the words between the number and the noun leave it a
        /// source count. `qualified`: the question says "at least".
        func clean(_ between: String?, qualified: Bool) -> Bool {
            for word in (between ?? "").split(whereSeparator: { !$0.isLetter }) {
                let lower = word.lowercased()
                if unitWords.contains(lower) || hardConnectors.contains(lower) { return false }
                // `5 Firmen und Quellen`: a capitalized noun joined to the sources.
                if softConnectors.contains(lower), !qualified,
                   (between ?? "").split(whereSeparator: { !$0.isLetter })
                       .contains(where: { $0.first?.isUppercase == true }) {
                    return false
                }
            }
            return true
        }
        /// `5 good sources of iron`: the sources belong to something else.
        func ofFollows(_ match: NSTextCheckingResult) -> Bool {
            let rest = (text as NSString).substring(from: match.range.location + match.range.length)
            return rest.range(of: #"^\s+of\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        for match in minAndMax.matches(in: text, range: whole) {
            if let low = group(match, 1).flatMap({ Int($0) }),
               let high = group(match, 2).flatMap({ Int($0) }),
               clean(group(match, 3), qualified: true) {
                consider(match.range.location, low, high)
            }
        }
        for (expression, qualified) in [(rangeOfSources, false), (betweenSources, false)] {
            for match in expression.matches(in: text, range: whole) {
                if let low = group(match, 1).flatMap({ Int($0) }),
                   let high = group(match, 2).flatMap({ Int($0) }),
                   clean(group(match, 3), qualified: qualified), !ofFollows(match) {
                    consider(match.range.location, low, high)
                }
            }
        }
        for match in labelCount.matches(in: text, range: whole) {
            guard let number = group(match, 2).flatMap({ Int($0) }) else { continue }
            if let qualifier = group(match, 1)?.lowercased(), isCap(qualifier) { continue }
            consider(match.range.location, number, nil)
        }
        for match in singleCount.matches(in: text, range: whole) {
            let qualifier = group(match, 1)?.lowercased()
            let minimum = qualifier.map(isMinimum) ?? false
            guard let number = group(match, 2).flatMap({ Int($0) }),
                  clean(group(match, 3), qualified: minimum) else { continue }
            if let qualifier, isCap(qualifier) { continue }
            if !minimum, ofFollows(match) { continue }
            consider(match.range.location, number, nil)
        }
        return best?.request
    }

    private static func isMinimum(_ qualifier: String) -> Bool {
        ["min", "mindestens", "at least", "least", "mehr als", "more than"]
            .contains { qualifier.hasPrefix($0) }
    }

    private static func isCap(_ qualifier: String) -> Bool {
        let words = ["max", "maximal", "maximum", "höchstens", "bis zu", "up to", "at most",
                     "no more than", "nicht mehr als", "maximal"]
        return words.contains { qualifier.hasPrefix($0) }
    }

    /// Words between a number and `Quellen` that show the number counts
    /// something else.
    private static let unitWords: Set<String> = [
        "jahr", "jahre", "jahren", "jahres", "year", "years", "tag", "tage", "tagen", "days",
        "day", "monat", "monate", "monaten", "months", "month", "woche", "wochen", "weeks",
        "week", "prozent", "percent", "stunden", "hours", "minuten", "minutes", "euro",
        "dollar", "uhr", "seiten", "pages", "wörter", "words", "zeichen",
    ]

    /// Words between the number and the noun that show the number counts
    /// something the sources only go with (`5 Firmen mit Quellen`).
    private static let hardConnectors: Set<String> = [
        "mit", "with", "für", "for", "von", "of", "aus", "from", "sowie", "plus", "inkl",
        "including",
    ]

    /// Joins two kinds of things only when a capitalized noun stands between.
    private static let softConnectors: Set<String> = ["und", "and", "oder", "or"]

    private static let noun = #"(?:quellen|quelle|sources?|webquellen|internetquellen|webseiten|websites?|belege)"#
    private static let minWord = #"(?:min(?:imum|destens|\.)?|mindestens|at least|least)"#
    private static let maxWord = #"(?:max(?:imum|imal|\.)?|höchstens|at most|up to|bis zu)"#
    private static let number = #"(?<![\p{L}\p{N}.,])(\d{1,3})(?![\d.,]\d)"#

    private static func expression(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// `minimum 30 max 40 Quellen`, `at least 10, at most 15 sources`.
    private static let minAndMax = expression(
        minWord + #"\s*:?\s*"# + number + #"\D{0,14}?"# + maxWord + #"\s*:?\s*(\d{1,3})\s+"#
            + #"((?:\p{L}+\s+){0,3}?)"# + noun + #"(?!\p{L})"#)

    /// `10–15 Quellen`, `10 bis 15 sources`.
    private static let rangeOfSources = expression(
        number + #"\s*(?:-|–|—|bis|to)\s*(\d{1,3})\s+((?:\p{L}+\s+){0,3}?)"# + noun + #"(?!\p{L})"#)

    /// `between 10 and 20 sources`, `zwischen 10 und 20 Quellen`.
    private static let betweenSources = expression(
        #"(?:between|zwischen)\s+"# + number + #"\s+(?:and|und)\s+(\d{1,3})\s+((?:\p{L}+\s+){0,3}?)"#
            + noun + #"(?!\p{L})"#)

    /// `Quellen: mindestens 10`.
    private static let labelCount = expression(
        #"(?<!\p{L})"# + noun + #"\s*:\s*("# + minWord + "|" + maxWord + #")?\s*(\d{1,3})(?!\d)(?![.,]\d)"#)

    /// `30 Quellen`, `mindestens 10 unabhängige Quellen`, `maximal 5 Quellen`.
    private static let singleCount = expression(
        #"(?:("# + minWord + "|" + maxWord + #"|ca\.?|etwa|about|around|mehr als|more than|no more than|nicht mehr als)\s*)?"#
            + number + #"\s+((?:\p{L}+\s+){0,3}?)"# + noun + #"(?!\p{L})"#)
}
