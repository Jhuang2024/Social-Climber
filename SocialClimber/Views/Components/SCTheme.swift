import SwiftUI
import UIKit

enum SCTheme {
    static let cardRadius: CGFloat = 18
    static let controlRadius: CGFloat = 14
    static let pageSpacing: CGFloat = 16
    /// The larger radius used by a screen's single hero header card
    /// (profile/detail headers), deliberately bigger than `cardRadius` so
    /// the one "headline" card per screen reads as more prominent.
    static let heroCardRadius: CGFloat = 24

    /// The app's brand color, read directly from the asset catalog by name.
    ///
    /// Deliberately not `Color.accentColor`: that static resolves against the
    /// current environment's `tint`, so anywhere a `.tint()` modifier sits
    /// above a view (e.g. RootTabView's monochrome tab bar tint) it silently
    /// substitutes that tint instead of the real brand color, which is what
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

    /// The app's editorial display face: serif (New York), matching the
    /// nav-title typography set in SocialClimberApp. Reserved for display
    /// moments: person names, hero numbers, score digits. Body text stays
    /// default SF; the contrast between the two is the identity.
    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// A small, curated set of tones for icons/cards that need to be
    /// tell-apart-able in a grid but don't carry genuinely different
    /// meaning on their own; used in place of grabbing whichever stock
    /// SwiftUI color happens to look distinct from its neighbor (the
    /// dashboard previously mixed blue/green/pink/orange/teal/purple/
    /// indigo, seven unrelated hues with no relationship to each other or
    /// to the brand accent, which reads as a template rather than one
    /// designed product). Each tone also carries a loose meaning so the
    /// choice is deliberate where it can be: `growth` for logging/activity,
    /// `alert` for what needs attention, `warm` for closeness/celebration,
    /// `cool` for neutral utility actions like import.
    enum Accents {
        static let primary = SCTheme.accent
        static let warm = Color(hue: 0.94, saturation: 0.55, brightness: 0.92)
        static let growth = Color(hue: 0.40, saturation: 0.45, brightness: 0.68)
        static let alert = Color(hue: 0.08, saturation: 0.65, brightness: 0.92)
        static let cool = Color(hue: 0.55, saturation: 0.45, brightness: 0.80)
    }
}

struct PolishedPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            // A faint brand glow bleeding down from the top instead of a
            // flat fill; on the app's committed dark look (see
            // INFOPLIST_KEY_UIUserInterfaceStyle) this gives every page an
            // ambient light source the cards sit under, rather than gray
            // boxes floating on plain black.
            .background {
                ZStack {
                    SCTheme.pageBackground
                    LinearGradient(colors: [SCTheme.accent.opacity(0.10), .clear],
                                   startPoint: .top, endPoint: .center)
                }
                .ignoresSafeArea()
            }
    }
}

extension View {
    func socialClimberPageBackground() -> some View {
        modifier(PolishedPageBackground())
    }

    func cardShadow() -> some View {
        // Deep enough to register on the app's committed dark background;
        // the old 6% was tuned for light gray and disappeared entirely on
        // near-black.
        shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 10)
    }

    /// Adds a clear "Done" button above the keyboard so text fields and text
    /// editors can be dismissed without needing a Return key or tapping
    /// somewhere else first.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
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
/// across the dashboard, empty states, and filter chips, gives every one
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
/// after (save/delete sheets): `.sensoryFeedback` needs the view to stay
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

/// The app's primary call-to-action style: a solid accent fill with white
/// text, a gentle press animation, and success haptics. Reusable everywhere a
/// prominent button is needed so they all look and feel identical.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = SCTheme.accent
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 13)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// A softer, tinted secondary action.
struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = SCTheme.accent
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(color)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 13)
            .padding(.horizontal, fullWidth ? 0 : 18)
            .background(color.opacity(configuration.isPressed ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryCTA: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primaryCTA(_ color: Color, fullWidth: Bool = true) -> PrimaryButtonStyle {
        PrimaryButtonStyle(color: color, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryCTA: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondaryCTA(_ color: Color, fullWidth: Bool = true) -> SecondaryButtonStyle {
        SecondaryButtonStyle(color: color, fullWidth: fullWidth)
    }
}

/// A small uppercased section header used inside cards and stacked layouts.
/// An optional trailing view (a badge, a count, an action) can be supplied;
/// omit it for a plain title-only header.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var icon: String?
    var accent: Color = SCTheme.accent
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, icon: String? = nil, accent: Color = SCTheme.accent, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 9) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1.4)
            Spacer()
            trailing()
        }
    }
}

extension View {
    /// Wraps any content in the app's standard card: thin material with a
    /// faint top-edge "sheen" so each card reads as a lit surface with
    /// depth rather than a flat gray rectangle (the single biggest tell
    /// separating premium dark UIs from default dark-mode grays), plus a
    /// border whose top edge is slightly brighter than its sides, the way
    /// light actually falls on a raised surface.
    func scCard(padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                              startPoint: .top, endPoint: .center))
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .cardShadow()
    }
}

/// A row of filled/hollow dots used to visualize a 1-5 rating (closeness,
/// priority), replaces the earlier `"●●●○○"` string, which VoiceOver read
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
