import AppKit
import SwiftUI

/// The few shared looks of the window: one accent, one card, one badge.
enum AppTheme {
    static let accent = Color.accentColor
    static let cardRadius: CGFloat = 14
}

extension View {
    /// The padded, rounded panel the screens are built from.
    func cardStyle() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }
}

struct ScreenTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small coloured word beside a card's title, such as "Connected".
struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}
