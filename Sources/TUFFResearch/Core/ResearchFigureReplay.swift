import Foundation

/// The answer of a finished run and the page texts its figure check used,
/// saved by `--save-pages` so the check can be run again, without a model or
/// a sandbox, with `--replay-figures`. A test aid: it is written only to the
/// file the user names.
public struct ResearchSavedPages: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public var number: Int
        public var url: String
        public var title: String
        /// The page text the figure check used, as the run recorded it.
        public var text: String

        public init(number: Int, url: String, title: String, text: String) {
            self.number = number
            self.url = url
            self.title = title
            self.text = text
        }
    }

    public var question: String
    /// The answer as the figure check saw it.
    public var answer: String
    /// Today's date as the check used it, `yyyy-MM-dd`.
    public var date: String
    public var pages: [Page]

    public init(question: String, answer: String, date: String, pages: [Page]) {
        self.question = question
        self.answer = answer
        self.date = date
        self.pages = pages
    }

    /// The saved form of a finished report, or nil for a partial report, which
    /// has no answer. The report needs `ResearchOptions.keepPageTexts`.
    public init?(report: ResearchReport) {
        guard report.endedEarly == nil else { return nil }
        self.init(
            question: report.question, answer: report.answer, date: report.checkedOn,
            pages: report.sources.map { source in
                Page(number: source.number, url: source.url, title: source.title,
                     text: report.checkedPages[source.number] ?? "")
            })
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func load(from path: String) throws -> ResearchSavedPages {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ResearchSavedPages.self, from: data)
    }
}

/// Runs the figure check on saved pages with the current and the candidate
/// rules, and tells which points differ. It makes no network call.
public enum ResearchFigureReplay {
    /// The points the check finds on the saved answer with `rules`.
    static func check(_ saved: ResearchSavedPages,
                      rules: ResearchFigureCheck.Rules) -> [ResearchUnverifiedFigure] {
        var texts: [Int: String] = [:]
        for page in saved.pages { texts[page.number] = page.text }
        return ResearchFigureCheck.unverified(
            answer: saved.answer, sourceTexts: texts, question: saved.question,
            today: saved.date, rules: rules)
    }

    /// The figure-check section for each rule set, then the points that only
    /// one of them flags.
    public static func render(_ saved: ResearchSavedPages) -> String {
        let current = check(saved, rules: .current)
        let candidate = check(saved, rules: .candidate)
        var text = ""
        for (label, found) in [("current", current), ("candidate", candidate)] {
            text += "# Figure check, \(label) rules (\(found.count))\n"
            var report = ResearchReport(
                question: saved.question, answer: saved.answer, sources: [], modelTurns: 0,
                budgetExhausted: false)
            report.unverifiedFigures = found
            text += report.figureCheckSection.isEmpty
                ? "\nnothing flagged\n" : report.figureCheckSection
            text += "\n"
        }
        let onlyCurrent = current.filter { !candidate.contains($0) }
        let onlyCandidate = candidate.filter { !current.contains($0) }
        text += "# Differences\n\n"
        if onlyCurrent.isEmpty, onlyCandidate.isEmpty {
            text += "the same points with both rules\n"
        }
        for (label, items) in [("only with the current rules", onlyCurrent),
                               ("only with the candidate rules", onlyCandidate)] {
            guard !items.isEmpty else { continue }
            text += "\(label) (\(items.count)):\n"
            for item in items { text += "- \(ResearchReport.figureCheckLine(item))\n" }
        }
        return ResearchText.terminalSafe(text)
    }
}
