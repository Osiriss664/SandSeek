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

/// The title row of a card that folds: an arrow, an icon, the title and a
/// status badge, with room for a short summary after the badge. Clicking
/// anywhere on that part of the row (the arrow, the icon, the title) folds or
/// opens the card. `accessory` sits to the right and does not fold it (a
/// spinner, the help button).
struct FoldingCardHeader<Summary: View, Accessory: View>: View {
    let icon: String
    let title: String
    /// What the card is about, for the screen reader: "Show model server details".
    let subject: String
    let badge: (label: String, color: Color)
    /// What the summary says, as text, so the screen reader can say it too.
    let summaryText: String?
    @Binding var folded: Bool
    let summary: Summary
    let accessory: Accessory

    init(icon: String, title: String, subject: String, badge: (label: String, color: Color),
         summaryText: String? = nil,
         folded: Binding<Bool>,
         @ViewBuilder summary: () -> Summary,
         @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        self.subject = subject
        self.badge = badge
        self.summaryText = summaryText
        _folded = folded
        self.summary = summary()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { folded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    StatusBadge(label: badge.label, color: badge.color)
                    summary
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? "Show the details" : "Hide the details")
            .accessibilityLabel((folded ? "Show " : "Hide ") + subject + " details")
            // The status is part of what a folded card says.
            .accessibilityValue(summaryText.map { badge.label + ", " + $0 } ?? badge.label)
            accessory
        }
    }
}

/// A small (i) button that opens a popover with the longer explanations of a
/// card, so the card itself stays short.
struct HelpPopoverButton<Content: View>: View {
    /// What the button is for, e.g. "About the model server".
    let label: String
    let content: Content
    @State private var shown = false

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(width: 360, alignment: .leading)
        }
    }
}

/// One paragraph in a help popover.
struct HelpParagraph: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
