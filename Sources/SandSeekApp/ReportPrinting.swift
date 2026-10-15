import AppKit
import SandSeekAppLogic
import UniformTypeIdentifiers

/// Prints a report or writes it to a PDF. The text comes from
/// `ResearchReportPrintText`; this draws it in a text view that is never shown
/// and hands it to AppKit's print system.
@MainActor
enum ReportPrinting {
    /// Asks where to save, then writes the report there as a PDF. Returns a
    /// short message for the report view: nil when the person cancelled.
    static func exportPDF(_ report: SavedResearchReport) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ResearchReportPrintText.suggestedFileName(for: report) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }

        // Printed to a temporary file first, then copied over in one atomic
        // write, so a failure never leaves a half-written PDF or damages one
        // that is already at the destination.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandSeek-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary().setObject(
            temporary as NSURL,
            forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        let operation = NSPrintOperation(view: textView(for: report, info: info), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = ResearchReportPrintText.suggestedFileName(for: report)
        guard operation.run(),
              FileManager.default.fileExists(atPath: temporary.path) else {
            fail("The PDF could not be written, so nothing was saved. Try another folder.")
            return "Not saved."
        }
        do {
            // Read and written in place of a move, which fails across disks.
            try Data(contentsOf: temporary).write(to: destination, options: .atomic)
            return "Saved."
        } catch {
            fail("The PDF could not be saved to that place: \(error.localizedDescription)")
            return "Not saved."
        }
    }

    /// Opens the standard print panel, which also offers Save as PDF.
    static func printReport(_ report: SavedResearchReport) {
        let info = printInfo()
        let operation = NSPrintOperation(view: textView(for: report, info: info), printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = ResearchReportPrintText.suggestedFileName(for: report)
        _ = operation.run()
    }

    // MARK: - Rendering

    /// A copy of the shared print settings, so changes here never reach other
    /// printing in the app, with margins and a page that fits the text.
    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// The report in a text view as wide as the paper's printable width and as
    /// tall as the text, which AppKit then cuts into pages.
    private static func textView(for report: SavedResearchReport, info: NSPrintInfo) -> NSTextView {
        let width = max(200, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = true
        view.drawsBackground = true
        view.backgroundColor = .white
        view.isAutomaticLinkDetectionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: width, height: 0)
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(ResearchReportPrintText.attributed(for: report))
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(used.height)))
        }
        return view
    }

    private static func fail(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not export the report"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
