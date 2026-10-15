import Foundation

/// The cautions a saved report carries, worded once for the report screen and
/// for the printed or exported PDF so the two never disagree.
extension SavedResearchReport {
    /// Shown when the research finished but the model wrote no answer.
    public var emptyAnswerNotice: String? {
        guard endedEarly == nil,
              answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "The model stopped without writing an answer. This usually means it used up its token budget while thinking. Try again, or turn thinking off for this mode in Settings."
    }

    /// Every caution about the answer, in the order the screen shows them.
    public var answerWarnings: [String] {
        var result: [String] = []
        if !unknownCitations.isEmpty {
            let list = unknownCitations.map { "[\($0)]" }.joined(separator: ", ")
            result.append("The answer cites \(list), which is not a page the research read.")
        }
        if unverifiedFigureCount > 0 {
            result.append("\(unverifiedFigureCount) \(unverifiedFigureCount == 1 ? "point" : "points") (figures, dates or names) could not be matched to the pages they cite. They are listed under Figure check below.")
        }
        if budgetExhausted {
            result.append("The research ran out of steps, so this answer may be incomplete.")
        }
        if stoppedRepeatedSearches {
            result.append("The research stopped early because the model kept repeating searches it had already run, so this answer may be incomplete.")
        }
        if sources.isEmpty,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append("No web page was read for this answer, so it comes from the model's memory or search previews and has no sources to check.")
        }
        if answerCutOff {
            result.append("The answer stopped at the model's length limit, so its end may be missing.")
        }
        if answerEndsMidSentence {
            result.append("The answer seems to stop mid-sentence and may be incomplete.")
        }
        if repeatedSourceEntries > 0, !sources.isEmpty {
            result.append("The answer's own source list repeats \(repeatedSourceEntries) \(repeatedSourceEntries == 1 ? "entry" : "entries") it already lists; only the pages under Sources were read.")
        }
        return result
    }

    /// Shown with the searches: one search may have missed other sources.
    public var singleSearchNotice: String? {
        searchQueries.count == 1
            ? "Only one search was run, so other sources may have been missed." : nil
    }
}
