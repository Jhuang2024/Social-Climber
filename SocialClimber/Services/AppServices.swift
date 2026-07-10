import Foundation
import SwiftData

/// The single shared `ModelContainer`, owned here (rather than inside
/// `SocialClimberApp`) so App Intents and the notification-action handler,
/// which can run before or without the SwiftUI scene, always reach the
/// same store the UI uses. Creation preserves every existing data-protection
/// behavior: path-change logging, post-migration snapshot, per-save backup
/// observation, and quarantine-then-retry instead of a destructive reset.
enum AppServices {
    static let container: ModelContainer = {
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self, CapturedMemory.self, MemoryFact.self,
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
            // Must run before anything else touches Person/Interaction:
            // heals the duplicate-UUID migration bug (see its doc comment)
            // before any code builds a dictionary keyed by `uuid`.
            PersonIdentityRepair.run(context: ModelContext(container))
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
}
