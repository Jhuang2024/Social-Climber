import SwiftUI
import SwiftData
import UserNotifications
import UIKit

@main
struct SocialClimberApp: App {
    init() {
        // So `UserDefaults.standard.bool(forKey:)` reads `true` for this
        // flag everywhere (including inside `CrossAppIntegrationManager`,
        // which doesn't go through `@AppStorage`) even before the Settings
        // screen has ever set it explicitly.
        UserDefaults.standard.register(defaults: ["crossAppSharingEnabled": true])

        // Editorial navigation titles: serif display type (New York), the
        // signature of the app's luxury-editorial identity, deliberately
        // NOT the rounded "sporty" face its sibling app LockedInFit uses.
        // Serif for display (titles, names), default SF for body text, is
        // the classic premium-editorial pairing. UIKit appearance is the
        // only lever for nav-title fonts; SwiftUI exposes none.
        Self.configureNavigationTitleTypography()

        // Post-event follow-up prompts ("Log it" / "Add note" / "Skip")
        // need their category registered and their actions routed before
        // the first notification could ever arrive.
        NotificationService.shared.registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = NotificationActionHandler.shared
    }

    private static func configureNavigationTitleTypography() {
        func serif(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: serif(size: 34, weight: .bold)]
        appearance.titleTextAttributes = [.font: serif(size: 17, weight: .semibold)]
    }

    /// The shared container now lives in `AppServices` (see its doc
    /// comment) so App Intents and notification actions, which can run
    /// without this scene, reach the exact same store. All the
    /// data-protection behavior (path-change logging, migration snapshot,
    /// auto-backup observer, quarantine-instead-of-reset) moved with it.
    let container = AppServices.container

    var body: some Scene {
        WindowGroup {
            // Body text stays default SF on purpose: the serif voice is
            // reserved for display type (nav titles, person names, hero
            // numbers; see configureNavigationTitleTypography and
            // SCTheme.displayName). Serif display over sans body is the
            // premium-editorial pairing; serif everywhere would read as a
            // book, not an interface.
            AppRootView()
        }
        .modelContainer(container)
    }
}
