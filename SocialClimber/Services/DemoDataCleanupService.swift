import Foundation
import SwiftData

enum DemoDataCleanupService {
    private static let cleanupKey = "didRemoveBundledDemoContacts.v1"

    private static let demoNames: Set<String> = [
        "Alex Rivera",
        "Dev Patel",
        "Jordan Lee",
        "Linda Huang",
        "Maya Chen",
        "Priya Sharma",
        "Sarah Kim",
    ]

    static func removeBundledDemoContactsIfNeeded(context: ModelContext) {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: cleanupKey) else { return }

        do {
            let people = try context.fetch(FetchDescriptor<Person>())
            let demoPeople = people.filter { demoNames.contains($0.name) }
            for person in demoPeople {
                context.delete(person)
            }

            let interactions = try context.fetch(FetchDescriptor<Interaction>())
            for interaction in interactions where interaction.people.isEmpty && isBundledDemoInteraction(interaction) {
                context.delete(interaction)
            }

            try context.save()
            defaults.set(true, forKey: cleanupKey)
        } catch {
            assertionFailure("Demo cleanup failed: \(error.localizedDescription)")
        }
    }

    private static func isBundledDemoInteraction(_ interaction: Interaction) -> Bool {
        let note = interaction.note.lowercased()
        return note.contains("garden planning")
            || note.contains("f1 season predictions")
            || note.contains("tahoe cabin trip")
            || note.contains("stats final")
            || note.contains("grad school timeline")
            || note.contains("vinyl and coffee gear")
    }
}
