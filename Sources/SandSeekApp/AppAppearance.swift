import AppKit
import SwiftUI

/// How the app looks: like the rest of the Mac, or always light or dark.
/// Stored under "AppAppearance"; the Mac's own setting is the default.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "AppAppearance"

    var id: Self { self }

    /// The saved choice, read straight from the defaults, for use before
    /// SwiftUI's views exist. An unknown value means System.
    static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Set on the whole app, so report windows, alerts and menus follow too.
    /// nil means "follow the Mac".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
