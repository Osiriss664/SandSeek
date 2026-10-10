import Foundation

/// Copies the reports TUFF's research screen saved into SandSeek's own
/// reports folder.
///
/// The originals are only read: nothing in the TUFF folder is moved, changed
/// or deleted. Each report is taken over once, keyed by its id. The ids that
/// were taken over are remembered in a small file of their own (outside the
/// reports folder, which the store reads), so a report the person deleted
/// from SandSeek does not come back at the next launch, and a second launch
/// copies nothing twice. The report format is not changed: the JSON file is
/// copied byte for byte.
public enum ResearchReportImporter {
    public struct Outcome: Equatable, Sendable {
        /// Reports copied by this call.
        public var copied = 0
        /// Reports not copied because they were taken over before, or are
        /// already in the folder.
        public var skipped = 0
        /// JSON files that are not readable reports.
        public var unreadable = 0

        public init(copied: Int = 0, skipped: Int = 0, unreadable: Int = 0) {
            self.copied = copied
            self.skipped = skipped
            self.unreadable = unreadable
        }
    }

    /// Where TUFF's research screen kept its reports.
    public nonisolated static func tuffReportsDirectory() -> URL {
        applicationSupport().appendingPathComponent("TUFF/Research Reports", isDirectory: true)
    }

    /// Where the ids of the taken-over reports are remembered.
    public nonisolated static func defaultLedgerURL() -> URL {
        applicationSupport().appendingPathComponent("SandSeek/State/imported-report-ids.json")
    }

    private nonisolated static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private struct Ledger: Codable {
        var importedIDs: [String]
    }

    /// Copies every report in `source` that is not yet in `destination` and
    /// not in the ledger. A missing `source` is no error: there is nothing to
    /// take over. Reports are looked at in the order of their file names.
    @discardableResult
    public nonisolated static func importReports(from source: URL,
                                                 into destination: URL,
                                                 ledger ledgerURL: URL) -> Outcome {
        let fileManager = FileManager.default
        var outcome = Outcome()
        var ledger = loadLedger(ledgerURL)
        var known = Set(ledger.importedIDs)
        let files = ((try? fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = ResearchReportStore.decoder
        var changed = false
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let report = try? decoder.decode(SavedResearchReport.self, from: data) else {
                outcome.unreadable += 1
                continue
            }
            let id = report.id.uuidString
            if known.contains(id) {
                outcome.skipped += 1
                continue
            }
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                // Nothing can be copied; try again at the next launch.
                outcome.unreadable += 1
                continue
            }
            let stem = ResearchReportStore.fileStem(for: report)
            let jsonTarget = destination.appendingPathComponent(stem + ".json")
            let markdownTarget = destination.appendingPathComponent(stem + ".md")
            do {
                try data.write(to: jsonTarget, options: .withoutOverwriting)
            } catch {
                if fileManager.fileExists(atPath: jsonTarget.path) {
                    // Already there, for example copied by hand: remember it.
                    outcome.skipped += 1
                    known.insert(id)
                    ledger.importedIDs.append(id)
                    changed = true
                } else {
                    outcome.unreadable += 1
                }
                continue
            }
            // The Markdown file for people: the original when it is there,
            // otherwise made from the report. Never over an existing file.
            let siblingMarkdown = file.deletingPathExtension().appendingPathExtension("md")
            let markdown = (try? Data(contentsOf: siblingMarkdown)) ?? Data(report.markdown.utf8)
            try? markdown.write(to: markdownTarget, options: .withoutOverwriting)
            known.insert(id)
            ledger.importedIDs.append(id)
            changed = true
            outcome.copied += 1
        }
        if changed { saveLedger(ledger, to: ledgerURL) }
        return outcome
    }

    private nonisolated static func loadLedger(_ url: URL) -> Ledger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
            return Ledger(importedIDs: [])
        }
        return ledger
    }

    private nonisolated static func saveLedger(_ ledger: Ledger, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Ledger(importedIDs: ledger.importedIDs.sorted())) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
