import Foundation
import SwiftData

/// Centralized "what happens after you log an interaction" logic, shared by
/// manual logging, the import-message flow, and event logging so they all:
///   • attach the interaction to its people
///   • update each person's last-contacted dates
///   • create + schedule a follow-up reminder when requested
enum InteractionSaver {
    /// Inserts `interaction`, links `people`, updates their contact dates, and
    /// returns a follow-up reminder if one was created.
    @discardableResult
    static func finalize(_ interaction: Interaction, people: [Person], context: ModelContext) -> Reminder? {
        interaction.people = people
        context.insert(interaction)
        applyClosenessImpact(of: interaction, to: people)
        for person in people {
            person.markContacted(type: interaction.type, date: interaction.date)
        }
        return scheduleFollowUpIfNeeded(for: interaction, people: people, context: context)
    }

    /// Applies `interaction`'s quality-based closeness delta to `people` via
    /// the centralized `ClosenessScoring`, and records what was *actually*
    /// applied to each person (post-clamp) so it can be reversed exactly.
    /// Two attendees can absorb the same nominal delta differently if one
    /// was already near the 1...5 ceiling/floor.
    static func applyClosenessImpact(of interaction: Interaction, to people: [Person]) {
        let nominal = ClosenessScoring.delta(forQuality: interaction.quality)
        guard nominal != 0 else {
            interaction.appliedClosenessDeltas = [:]
            return
        }
        var applied: [PersistentIdentifier: Int] = [:]
        for person in people {
            applied[person.persistentModelID] = person.adjustCloseness(by: nominal)
        }
        interaction.appliedClosenessDeltas = applied
    }

    /// Undoes the closeness delta this interaction previously applied to its
    /// people, using the exact per-person amount recorded at apply time.
    /// Call before deleting an interaction, or before re-applying a new
    /// delta when its quality changes.
    static func reverseClosenessImpact(of interaction: Interaction) {
        let applied = interaction.appliedClosenessDeltas
        guard !applied.isEmpty else { return }
        for person in interaction.people {
            guard let delta = applied[person.persistentModelID], delta != 0 else { continue }
            person.adjustCloseness(by: -delta)
        }
        interaction.appliedClosenessDeltas = [:]
    }

    /// Changes an existing interaction's quality, correctly moving its
    /// people's closeness from the old delta to the new one so edits never
    /// double-count or leave a stale adjustment behind.
    ///
    /// Note: interactions restored from a JSON import or seed data are
    /// inserted directly (their closeness contribution is already baked
    /// into the restored/seeded `Person.closeness`, so applying it again
    /// here would double-count), so they start with no recorded delta.
    /// Editing one of those interactions' quality applies a fresh delta
    /// going forward rather than retroactively correcting historical
    /// closeness this app never separately tracked per interaction.
    static func updateQuality(of interaction: Interaction, to quality: Int) {
        reverseClosenessImpact(of: interaction)
        interaction.quality = quality
        applyClosenessImpact(of: interaction, to: interaction.people)
    }

    /// Creates and schedules a follow-up reminder from an interaction's
    /// follow-up flag, honoring an explicit follow-up date and "next move".
    @discardableResult
    static func scheduleFollowUpIfNeeded(for interaction: Interaction, people: [Person], context: ModelContext) -> Reminder? {
        guard interaction.followUpNeeded, let first = people.first else { return nil }
        let due = interaction.followUpDate
            ?? Calendar.current.date(byAdding: .day, value: 3, to: .now)
            ?? .now
        let names = people.map(\.firstName).joined(separator: " & ")
        let title = interaction.nextMove.isEmpty
            ? "Follow up with \(names)"
            : interaction.nextMove
        let reminder = Reminder(
            title: title,
            dueDate: due,
            type: .followUp,
            person: first,
            notes: interaction.nextMove
        )
        context.insert(reminder)
        // A follow-up the user asked to remember is a strong "why reminders
        // help" moment — request permission contextually, then schedule.
        Task {
            await NotificationService.shared.requestPermissionContextually()
            NotificationService.shared.schedule(reminder: reminder)
        }
        return reminder
    }
}
