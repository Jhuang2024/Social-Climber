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
        for person in people {
            person.markContacted(type: interaction.type, date: interaction.date)
            person.applyInteractionQuality(interaction.quality)
        }
        return scheduleFollowUpIfNeeded(for: interaction, people: people, context: context)
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
        NotificationService.shared.schedule(reminder: reminder)
        return reminder
    }
}
