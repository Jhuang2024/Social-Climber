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
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(title)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
        .cardShadow()
    }
}
