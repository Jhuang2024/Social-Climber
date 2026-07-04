import SwiftUI

enum SCTheme {
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 14
    static let pageSpacing: CGFloat = 16

    static var pageBackground: Color {
        Color(.systemGroupedBackground)
    }

    static var cardBackground: Color {
        Color(.secondarySystemGroupedBackground)
    }

    static var elevatedBackground: Color {
        Color(.tertiarySystemGroupedBackground)
    }
}

struct PolishedPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
    }
}

extension View {
    func socialClimberPageBackground() -> some View {
        modifier(PolishedPageBackground())
    }

    func cardShadow() -> some View {
        shadow(color: Color.black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

struct SectionLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.10), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
