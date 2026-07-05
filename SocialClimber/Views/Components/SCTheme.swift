import SwiftUI
import UIKit

enum SCTheme {
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 14
    static let pageSpacing: CGFloat = 16

    /// The app's brand color, read directly from the asset catalog by name.
    ///
    /// Deliberately not `Color.accentColor`: that static resolves against the
    /// current environment's `tint`, so anywhere a `.tint()` modifier sits
    /// above a view (e.g. RootTabView's monochrome tab bar tint) it silently
    /// substitutes that tint instead of the real brand color — which is what
    /// made buttons that filled themselves with `Color.accentColor` render
    /// white-on-white. `Color("AccentColor")` reads the asset unconditionally.
    static var accent: Color {
        Color("AccentColor")
    }

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

    /// Adds a "Done" checkmark above the keyboard so text fields and text
    /// editors can be dismissed without needing a Return key or tapping
    /// somewhere else first.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

struct SectionLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SCTheme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(SCTheme.accent.opacity(configuration.isPressed ? 0.18 : 0.10), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
