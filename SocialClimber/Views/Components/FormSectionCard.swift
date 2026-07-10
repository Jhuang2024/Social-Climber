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
        // the two card wrappers are visually indistinguishable — this one
        // just adds the titled header.
        .scCard()
    }
}
