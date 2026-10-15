import Foundation
import SandSeekCore

/// A page the research tried to read and could not, with the reason.
public struct UnreadablePage: Equatable, Sendable {
    public let address: String
    public let reason: String

    public init(address: String, reason: String) {
        self.address = address
        self.reason = reason
    }

    /// The page and the reason on one line, as the report and the print-out
    /// word it.
    public var line: String { "\(address) \u{2014} \(reason)" }
}

extension SavedResearchReport {
    /// The pages that could not be read, in the order they were tried, taken
    /// from the run's steps: a failure that comes right after the step that
    /// started reading an address. Nothing for a run without such failures.
    public var unreadablePages: [UnreadablePage] {
        Self.unreadablePages(in: steps)
    }

    static func unreadablePages(in steps: [ResearchStep]) -> [UnreadablePage] {
        var result: [UnreadablePage] = []
        guard steps.count > 1 else { return result }
        for index in 1..<steps.count {
            let failure = steps[index]
            let reading = steps[index - 1]
            guard failure.kind == .failed, reading.kind == .reading else { continue }
            let address = ResearchText.capped(ResearchText.url(reading.text), limit: 500)
            let lowered = address.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { continue }
            let reason = ResearchText.oneLine(failure.text, limit: 300)
            // Messages about the run (stopped) or about a page that was read
            // (moved to another address) are not failed reads.
            guard !reason.isEmpty, !reason.hasPrefix("open_page:"),
                  !reason.hasPrefix("Stopped"), !reason.hasPrefix("Failed:") else { continue }
            let page = UnreadablePage(address: address, reason: reason)
            if !result.contains(page) { result.append(page) }
        }
        return result
    }

    /// The "Pages that could not be read" section of the Markdown report, or
    /// nothing when every page was read.
    static func unreadablePagesMarkdown(_ pages: [UnreadablePage]) -> String {
        guard !pages.isEmpty else { return "" }
        var text = "\n## Pages that could not be read\n\n"
        for page in pages {
            text += "- " + ResearchText.inertMarkdown(page.line) + "\n"
        }
        return ResearchText.terminalSafe(text)
    }
}
