import Foundation

/// Cleans text that came from the web before it reaches a terminal or the
/// model.
public enum ResearchText {
    /// Removes C0 and C1 control characters other than tab and newline, and
    /// the Unicode bidi overrides. Page titles, answers and URLs are printed
    /// to a terminal, where an ESC sequence could rewrite the screen, change
    /// the window title or hide part of the report.
    public static func terminalSafe(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isUnsafe(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// A URL as one printable token: control characters and whitespace removed.
    public static func url(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
        where !isUnsafe(scalar) && !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A: return false
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}
