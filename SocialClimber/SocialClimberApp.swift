import SwiftUI
import SwiftData
import UserNotifications
import UIKit

@main
struct SocialClimberApp: App {
    /// The shared container lives in `AppServices` (see its doc comment) so App
    /// Intents and notification actions, which can run without this scene, reach
    /// the exact same store. All the data-protection behavior (path-change
    /// logging, migration snapshot, auto-backup observer,
    /// quarantine-instead-of-reset) moved with it.
    let container = AppServices.container

    init() {
        // So `UserDefaults.standard.bool(forKey:)` reads `true` for this flag
        // everywhere (including inside `CrossAppIntegrationManager`, which
        // doesn't go through `@AppStorage`) even before the Settings screen has
        // ever set it explicitly.
        UserDefaults.standard.register(defaults: ["crossAppSharingEnabled": true])

        // Notification category/quiet-hours/preview defaults, so a fresh install
        // has sensible settings before the Settings screen ever sets them.
        NotificationSettings.registerDefaults()

        // Editorial navigation titles: serif display type (New York), the
        // signature of the app's luxury-editorial identity.
        Self.configureNavigationTitleTypography()

        // Register the actionable categories (post-event follow-up prompts plus
        // the reminder/contact/capture categories) and route their actions
        // before the first notification could ever arrive. No permission prompt
        // here; that stays contextual (see requestPermissionContextually).
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

    var body: some Scene {
        WindowGroup {
            // Body text stays default SF on purpose: the serif voice is reserved
            // for display type (nav titles, person names, hero numbers).
            AppRootView()
        }
        .modelContainer(container)
    }
}
