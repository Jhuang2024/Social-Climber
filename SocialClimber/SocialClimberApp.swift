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

        // Editorial navigation titles: heavy rounded display type matched
        // to the root-level .fontDesign(.rounded), so screen titles read as
        // part of one designed type system instead of stock chrome sitting
        // on top of it. UIKit appearance is the only lever for nav-title
        // fonts; SwiftUI exposes none.
        Self.configureNavigationTitleTypography()
    }

    private static func configureNavigationTitleTypography() {
        func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: rounded(size: 34, weight: .heavy)]
        appearance.titleTextAttributes = [.font: rounded(size: 17, weight: .bold)]
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
            AppRootView()
                // Rounded design was previously reserved for the score ring
                // and avatar initials; applying it once here at the root
                // cascades it to every Text/Label in the app instead of 100%
                // default system text everywhere else, for one consistent
                // type identity (anything more local can still opt out with
                // its own .fontDesign).
                .fontDesign(.rounded)
        }
        .modelContainer(container)
    }
}
