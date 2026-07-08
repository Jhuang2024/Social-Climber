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
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }
}
