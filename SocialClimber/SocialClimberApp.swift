import SwiftUI
import SwiftData

@main
struct SocialClimberApp: App {
    init() {
        // So `UserDefaults.standard.bool(forKey:)` reads `true` for this
        // flag everywhere (including inside `CrossAppIntegrationManager`,
        // which doesn't go through `@AppStorage`) even before the Settings
        // screen has ever set it explicitly.
        UserDefaults.standard.register(defaults: ["crossAppSharingEnabled": true])
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
        do {
            let container = try ModelContainer(for: schema)
            // Never a destructive reset on failure: a broken migration
            // still fails loudly above via `fatalError`, rather than
            // silently deleting and recreating an empty store. This just
            // snapshots the data once a migration has succeeded, so the
            // next launch (paired with `AppRootView`'s check) can catch a
            // migration that quietly wiped something.
            SchemaVersionGuard.backupIfNeeded(container: container)
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(container)
    }
}
