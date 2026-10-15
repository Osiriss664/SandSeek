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
    /// started reading an address. An address that was read later (a retry
    /// that worked) or that is one of the report's sources is left out.
    /// Nothing for a run without such failures.
    public var unreadablePages: [UnreadablePage] {
        Self.unreadablePages(in: steps, sources: sources.map(\.url))
    }

    static func unreadablePages(in steps: [ResearchStep],
                                sources: [String] = []) -> [UnreadablePage] {
        var result: [UnreadablePage] = []
        guard steps.count > 1 else { return result }
        let readSources = Set(sources.map { ResearchText.capped(ResearchText.url($0), limit: 500) })

        /// The address a step started reading, when it is a web address.
        func readAddress(at index: Int) -> String? {
            let reading = steps[index]
            guard reading.kind == .reading else { return nil }
            let address = ResearchText.capped(ResearchText.url(reading.text), limit: 500)
            let lowered = address.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
            return address
        }

        /// The reason a read failed, when the step after `index` is a failed read.
        func failureReason(after index: Int) -> String? {
            guard index + 1 < steps.count, steps[index + 1].kind == .failed else { return nil }
            let reason = ResearchText.oneLine(steps[index + 1].text, limit: 300)
            // Messages about the run (stopped) or about a page that was read
            // (moved to another address) are not failed reads.
            guard !reason.isEmpty, !reason.hasPrefix("open_page:"),
                  !reason.hasPrefix("Stopped"), !reason.hasPrefix("Failed:") else { return nil }
            return reason
        }

        for index in 0..<(steps.count - 1) {
            guard let address = readAddress(at: index),
                  let reason = failureReason(after: index) else { continue }
            if readSources.contains(address) { continue }
            // A later read of the same address that did not fail means the
            // page was read after all.
            let readLater = ((index + 1)..<steps.count).contains { later in
                readAddress(at: later) == address && failureReason(after: later) == nil
            }
            if readLater { continue }
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
            let address = ResearchText.markdownURL(page.address)
            text += "- [\(address)](\(address)) \u{2014} "
                + ResearchText.inertMarkdown(page.reason) + "\n"
        }
        return ResearchText.terminalSafe(text)
    }
}
