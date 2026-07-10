import Foundation
import SwiftData

/// One entity's live count, for the debug diagnostics list.
struct RecordCountEntry: Identifiable {
    let label: String
    let count: Int
    var id: String { label }
}

/// Cheap, read-only counts of Social Climber's core entities, shared by
/// `DataLossGuard` (the sudden-zero check) and the debug diagnostics
/// screen. Uses `fetchCount` rather than fetching and counting arrays, so
/// this is safe to call on every launch without loading real objects.
enum RecordCounts {
    static func total(in context: ModelContext) -> Int {
        breakdown(in: context).reduce(0) { $0 + $1.count }
    }

    static func breakdown(in context: ModelContext) -> [RecordCountEntry] {
        [
            RecordCountEntry(label: "People", count: count(Person.self, in: context)),
            RecordCountEntry(label: "Interactions", count: count(Interaction.self, in: context)),
            RecordCountEntry(label: "Events", count: count(Event.self, in: context)),
            RecordCountEntry(label: "Reminders", count: count(Reminder.self, in: context)),
            RecordCountEntry(label: "Gift Ideas", count: count(GiftIdea.self, in: context)),
            RecordCountEntry(label: "Important Dates", count: count(ImportantDate.self, in: context)),
            RecordCountEntry(label: "Voice Notes", count: count(VoiceNote.self, in: context)),
            RecordCountEntry(label: "Captures", count: count(CapturedMemory.self, in: context)),
            RecordCountEntry(label: "Memory Facts", count: count(MemoryFact.self, in: context)),
        ]
    }

    private static func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
    }
}
