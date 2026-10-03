import Foundation
import Observation
import TUFFResearchCore

/// One entry in a run's progress list.
public struct ResearchStep: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case turn
        case thinking
        case searching
        case reading
        case failed
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    /// Seconds since the run started.
    public let elapsed: Double

    public init(id: Int, kind: Kind, text: String, elapsed: Double) {
        self.id = id
        self.kind = kind
        self.text = text
        self.elapsed = elapsed
    }
}

/// A finished research run as the app keeps it.
public struct SavedResearchReport: Codable, Equatable, Identifiable, Sendable {
    public struct Source: Codable, Equatable, Identifiable, Sendable {
        public let number: Int
        public let title: String
        public let url: String
        public var id: Int { number }

        public init(number: Int, title: String, url: String) {
            self.number = number
            self.title = title
            self.url = url
        }

        /// The address only when it is plain http or https, the only kinds
        /// the app will hand to the browser.
        public var webURL: URL? {
            guard let url = URL(string: ResearchText.url(url)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { return nil }
            return url
        }

        public var host: String {
            webURL?.host ?? ResearchText.url(url)
        }
    }

    public let id: UUID
    public let question: String
    public let answer: String
    public let sources: [Source]
    public let model: String
    public let createdAt: Date
    public let durationSeconds: Double
    public let budgetExhausted: Bool
    public let unknownCitations: [Int]
    public let steps: [ResearchStep]
    /// The report as `tuff research` prints it, made inert for viewers.
    public let markdown: String

    public init(id: UUID = UUID(),
                report: ResearchReport,
                model: String,
                createdAt: Date,
                durationSeconds: Double,
                steps: [ResearchStep]) {
        self.id = id
        question = ResearchText.terminalSafe(report.question)
        answer = ResearchText.terminalSafe(report.answer)
        sources = report.sources.map {
            Source(number: $0.number,
                   title: ResearchText.terminalSafe($0.title),
                   url: ResearchText.url($0.url))
        }
        self.model = model
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        budgetExhausted = report.budgetExhausted
        unknownCitations = report.unknownCitations
        self.steps = steps
        markdown = report.markdown
    }
}

/// Saved reports, one JSON file for the app and one Markdown file for
/// people, in a single folder. Files are only ever created new.
@MainActor @Observable
public final class ResearchReportStore {
    public private(set) var reports: [SavedResearchReport] = []
    public private(set) var lastError: String?
    public let directory: URL

    public init(directory: URL = ResearchReportStore.defaultDirectory()) {
        self.directory = directory
        reload()
    }

    public nonisolated static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("TUFF/Research Reports", isDirectory: true)
    }

    public func reload() {
        let decoder = Self.decoder
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        reports = files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    try? decoder.decode(SavedResearchReport.self, from: $0)
                }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func report(id: UUID?) -> SavedResearchReport? {
        guard let id else { return nil }
        return reports.first { $0.id == id }
    }

    public func save(_ report: SavedResearchReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(report)
        try data.write(to: jsonURL(for: report), options: .withoutOverwriting)
        try Data(report.markdown.utf8).write(to: markdownURL(for: report), options: .withoutOverwriting)
        reports.removeAll { $0.id == report.id }
        reports.insert(report, at: 0)
        lastError = nil
    }

    /// Moves both files to the Trash.
    public func delete(_ report: SavedResearchReport) {
        for url in [jsonURL(for: report), markdownURL(for: report)]
        where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                lastError = "Could not move the report to the Trash: \(error.localizedDescription)"
                return
            }
        }
        reports.removeAll { $0.id == report.id }
    }

    public func markdownURL(for report: SavedResearchReport) -> URL {
        directory.appendingPathComponent(fileStem(for: report) + ".md")
    }

    func jsonURL(for report: SavedResearchReport) -> URL {
        directory.appendingPathComponent(fileStem(for: report) + ".json")
    }

    /// The date and the start of the id: sortable in Finder and never taken
    /// from the question, which could hold anything.
    private func fileStem(for report: SavedResearchReport) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "\(formatter.string(from: report.createdAt)) \(report.id.uuidString.prefix(8))"
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
