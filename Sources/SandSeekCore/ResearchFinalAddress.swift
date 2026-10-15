import Foundation

/// The check a page address gets on the Mac after the sandbox has followed its
/// redirects. The sandbox checks every address it connects to, but it is a
/// program in a VM that reaches the internet; what it reports is web content
/// until the Mac has looked at it. So the address a page ended up at passes
/// the same rules as the one the model asked for (`ResearchAgent.isPrivateAddress`)
/// before it becomes a source in a report, is cited or offered with "Open…".
public enum ResearchFinalAddress {
    /// Why `address` may not be used as a source, in words that fit after
    /// "the sandbox returned a page address that", or nil when it passes:
    /// it must be http or https, carry no user name or password, and its host
    /// must not be a local or private network name or number (loopback,
    /// private, link-local, carrier-grade NAT, multicast and reserved ranges,
    /// `localhost`, `*.local`, single-label names, odd spellings of numbers).
    /// The check is pure; it looks nothing up. The Mac's own public addresses
    /// are refused by the sandbox on every hop (Sandbox/server.py); the Mac
    /// side does not know them.
    public static func problem(with address: String) -> String? {
        let lowered = address.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else {
            return "is not http or https"
        }
        if hasCredentials(address) {
            return "carries a user name or password"
        }
        if ResearchAgent.isPrivateAddress(url: address) {
            return "is on a local or private network"
        }
        return nil
    }

    /// Whether the part between `://` and the first `/`, `?` or `#` holds an
    /// `@`, which separates a user name and password from the host.
    static func hasCredentials(_ address: String) -> Bool {
        guard let marker = address.range(of: "://") else { return false }
        let authority = address[marker.upperBound...].prefix { !"/?#".contains($0) }
        return authority.contains("@")
    }
}
