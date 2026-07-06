import Foundation
import SwiftData

/// In-memory container pre-filled with seed data for SwiftUI previews.
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let schema = Schema([
            Person.self, Interaction.self, GiftIdea.self, Reminder.self,
            ImportantDate.self, VoiceNote.self, ConversationSummary.self,
            Event.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        SeedData.seed(context: container.mainContext)
        return container
    }()

    static var samplePerson: Person {
        let people = try? container.mainContext.fetch(FetchDescriptor<Person>(sortBy: [SortDescriptor(\.name)]))
        return people?.first ?? Person(name: "Sample Person", relationshipToMe: "Friend")
    }
}
