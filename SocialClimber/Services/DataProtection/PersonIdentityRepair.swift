import Foundation
import SwiftData

/// Heals a real migration bug: `Person.uuid`/`Interaction.uuid` were added
/// as lightweight-migration defaults (`= UUID()`). SwiftData/Core Data
/// evaluates a new attribute's default expression exactly once per
/// migration and stamps that same literal onto every pre-existing row,
/// rather than generating a fresh value per row. Every Person (and
/// Interaction) that existed before those fields were introduced therefore
/// collapsed onto one shared UUID. Anything that builds a
/// `Dictionary(uniqueKeysWithValues:)` keyed by `uuid` then crashes the
/// instant two rows share it (`Fatal error: Duplicate values for key`).
///
/// This runs once per launch, is a cheap no-op once nothing collides, and
/// reassigns a fresh UUID to every row after the first in each colliding
/// group so the "stable identity" invariant those fields exist for holds
/// again going forward.
enum PersonIdentityRepair {
    static func run(context: ModelContext) {
        var didRepair = false
        didRepair = repairPeople(context: context) || didRepair
        didRepair = repairInteractions(context: context) || didRepair
        guard didRepair else { return }
        try? context.save()
    }

    @discardableResult
    private static func repairPeople(context: ModelContext) -> Bool {
        guard let people = try? context.fetch(FetchDescriptor<Person>()) else { return false }
        var seen: Set<UUID> = []
        var repaired = false
        for person in people {
            if seen.contains(person.uuid) {
                person.uuid = UUID()
                repaired = true
            }
            seen.insert(person.uuid)
        }
        return repaired
    }

    @discardableResult
    private static func repairInteractions(context: ModelContext) -> Bool {
        guard let interactions = try? context.fetch(FetchDescriptor<Interaction>()) else { return false }
        var seen: Set<UUID> = []
        var repaired = false
        for interaction in interactions {
            if seen.contains(interaction.uuid) {
                interaction.uuid = UUID()
                repaired = true
            }
            seen.insert(interaction.uuid)
        }
        return repaired
    }
}
