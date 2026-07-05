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

/// A press-responsive style for the card-like tappable buttons scattered
/// across the dashboard, empty states, and filter chips — gives every one
/// of them the same gentle scale/dim feedback instead of the dead flatness
/// of `.plain`.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Imperative haptics for actions that dismiss their view immediately
/// after (save/delete sheets) — `.sensoryFeedback` needs the view to stay
/// mounted to observe the state change, which a dismissing sheet can't
/// guarantee.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// A row of filled/hollow dots used to visualize a 1-5 rating (closeness,
/// priority) — replaces the earlier `"●●●○○"` string, which VoiceOver read
/// as a garble of bullet characters instead of a real value.
struct DotsRow: View {
    let value: Int
    var total: Int = 5
    var color: Color = SCTheme.accent
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index < value ? color : color.opacity(0.2))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) out of \(total)")
    }
}
