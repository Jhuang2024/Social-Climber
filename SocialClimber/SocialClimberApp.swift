import SwiftUI
import SwiftData
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
        // signature of the app's luxury-editorial identity — deliberately
        // NOT the rounded "sporty" face its sibling app LockedInFit uses.
        // Serif for display (titles, names), default SF for body text, is
        // the classic premium-editorial pairing. UIKit appearance is the
        // only lever for nav-title fonts; SwiftUI exposes none.
        Self.configureNavigationTitleTypography()
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

    let container: ModelContainer = {
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self,
        ])
        // Resolved the same way `ModelContainer(for: schema)` resolves it
        // internally, so this reflects the real store location even before
        // the container itself opens.
        let storeURL = ModelConfiguration().url
        PersistenceGuard.checkAndLogPathChange(currentPath: storeURL.path)

        func open() throws -> ModelContainer {
            let container = try ModelContainer(for: schema)
            // Never a silent destructive reset: this just snapshots data
            // once a migration has succeeded (`SchemaVersionGuard`), and
            // watches for every future save (`AutoBackupObserver`), so the
            // next launch (paired with `AppRootView`'s check) can catch
            // anything that quietly went wrong.
            SchemaVersionGuard.backupIfNeeded(container: container)
            AutoBackupObserver.start(container: container)
            return container
        }

        do {
            return try open()
        } catch {
            // The store exists but SwiftData can't open it at all
            // (corruption, an interrupted write, an unreconcilable
            // migration). Crashing on every subsequent launch is exactly
            // what an unrecoverable crash loop looks like from the
            // outside, and it's strictly worse than recovering: quarantine
            // (never delete) the unreadable files and try once more with a
            // fresh store. `AppRootView`'s data-loss check then surfaces
            // the recovery screen on this very next launch instead of this
            // happening silently.
            PersistenceRecovery.quarantineUnreadableStore(at: storeURL)
            do {
                return try open()
            } catch {
                fatalError("Could not create ModelContainer even after quarantining the existing store: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            // Body text stays default SF on purpose: the serif voice is
            // reserved for display type (nav titles, person names, hero
            // numbers — see configureNavigationTitleTypography and
            // SCTheme.displayName). Serif display over sans body is the
            // premium-editorial pairing; serif everywhere would read as a
            // book, not an interface.
            AppRootView()
        }
        .modelContainer(container)
    }
}
