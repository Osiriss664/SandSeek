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

    /// Makes Markdown safe to open in a viewer. A page could otherwise steer
    /// the model into writing `![x](https://tracker/?q=…)` or HTML such as
    /// `<div style="background:url(…)">`, which a viewer would fetch as soon
    /// as the saved report is opened, or a `javascript:` or `file:` link.
    /// Images become plain links, every `<` is escaped so no HTML or
    /// autolink is rendered, and links to anything but http and https are
    /// reduced to their text. Control and invisible characters are removed
    /// first, so one placed inside the syntax, such as between `!` and `[`,
    /// cannot hide it from these rules and be stripped afterwards.
    public static func inertMarkdown(_ text: String) -> String {
        var result = terminalSafe(text).replacingOccurrences(of: "![", with: "[")
        result = replacing(linkDefinition, in: result) { label, target in
            isWebURL(target) ? nil : "\\[\(label)\\]: (link removed)"
        }
        result = replacing(inlineLink, in: result) { label, target in
            isWebURL(target) ? nil : "\(label) (link removed)"
        }
        // A definition can also sit inside a quote or list item, or have a
        // label that spans lines. Escaping the bracket before `]:` stops any
        // remaining one from being read as a definition.
        result = replacing(definitionEnd, in: result) { backslashes, target in
            isWebURL(target) ? nil : "\(backslashes)\\]:"
        }
        return result.replacingOccurrences(of: "<", with: "\\<")
    }

    static func isWebURL(_ target: String) -> Bool {
        let lowered = target.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// Replaces each match whose (label, target) the closure maps to a string;
    /// nil keeps the match as it is.
    private static func replacing(_ expression: NSRegularExpression, in text: String,
                                  _ replacement: (String, String) -> String?) -> String {
        let result = NSMutableString(string: text)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let label = result.substring(with: match.range(at: 1))
            let target = result.substring(with: match.range(at: 2))
            if let new = replacement(label, target) {
                result.replaceCharacters(in: match.range, with: new)
            }
        }
        return result as String
    }

    /// `[label](target "title")`, with an optional `<target>`.
    private static let inlineLink = try! NSRegularExpression(
        pattern: #"\[([^\]\n]*)\]\(\s*<?([^\s)>]*)>?[^)\n]*\)"#)

    /// `[label]: target` at the start of a line.
    private static let linkDefinition = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*<?([^\s>]*)>?.*$"#,
        options: [.anchorsMatchLines])

    /// `]:` and the target after it (possibly on the next line), unless the
    /// bracket is already escaped by an odd number of backslashes. The target
    /// is read by a lookahead, so only the backslashes and `]:` are replaced.
    private static let definitionEnd = try! NSRegularExpression(
        pattern: #"(?<!\\)((?:\\\\)*)\]:(?=[ \t]*\n?[ \t]*<?([^\s>]*))"#)

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

    /// Text on one line: unsafe characters removed, runs of whitespace and
    /// line breaks turned into one space, cut to `limit` characters.
    public static func oneLine(_ text: String, limit: Int) -> String {
        let line = terminalSafe(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
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
        case 0x202A...0x202E, 0x2060...0x2069: return true
        case 0xAD, 0x200B...0x200F, 0x2028, 0x2029, 0xFEFF, 0xE0000...0xE007F: return true
        // More invisible characters used to hide text: the supplementary
        // variation selectors, fillers and blanks. U+FE0F (emoji) stays.
        case 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F, 0x2800, 0x3164,
             0xFE00...0xFE0E, 0xFFA0, 0xE0100...0xE01EF: return true
        default: return false
        }
    }
}
