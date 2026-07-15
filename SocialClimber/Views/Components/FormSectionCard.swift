import SwiftUI

/// A titled card used on the dashboard and profile screens.
struct FormSectionCard<Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder var content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(SCTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.4)
                Spacer()
            }
            content
        }
        // Same lit-surface chrome as scCard (sheen + top-bright border), so
        // the two card wrappers are visually indistinguishable; this one
        // just adds the titled header.
        .scCard()
    }
}

/// A tappable row that expands a capped list in place instead of hiding the
/// remainder behind a dead "+ N more" label. Used anywhere a card shows only
/// the first few of a longer list; binding `expanded` to the caller's state
/// lets the list re-render with everything shown, and tap again to collapse.
struct ExpandMoreButton: View {
    /// How many items are currently hidden (only meaningful when collapsed).
    let hiddenCount: Int
    @Binding var expanded: Bool
    /// Plural noun for the hidden items, e.g. "more", "more changes".
    var noun: String = "more"

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                Text(expanded ? "Show less" : "+ \(hiddenCount) \(noun)")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(SCTheme.accent)
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
    }
}
