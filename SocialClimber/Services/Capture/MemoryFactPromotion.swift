import Foundation
import SwiftData

/// Explicit, user-confirmed promotions of a suggested `MemoryFact` into a
/// real profile field or scheduled record. Automation never does any of
/// this on its own — `CaptureProcessor` deliberately never writes to
/// `Person.birthday` or schedules a reminder with an invented date; these
/// are the only paths that do, and every one of them requires a direct,
/// explicit tap from the user.
@MainActor
enum MemoryFactPromotion {
    /// Promotes an `.importantDate` fact into the person's canonical
    /// `birthday` field. Leaves the fact around (marked `.superseded`) so
    /// its provenance stays visible; does nothing if the person already
    /// has a birthday or the fact has no attributed person/date.
    static func confirmAsBirthday(_ fact: MemoryFact, context: ModelContext) {
        guard fact.type == .importantDate, let person = fact.person, let date = fact.dateValue else { return }
        guard person.birthday == nil else { return }
        person.birthday = date
        NotificationService.shared.scheduleBirthday(for: person)
        fact.status = .superseded
        fact.markUserEdited()
    }

    /// Promotes an `.importantDate` fact into a standalone, scheduled
    /// `ImportantDate` record for its attributed person.
    static func confirmAsImportantDate(_ fact: MemoryFact, context: ModelContext) {
        guard fact.type == .importantDate, let person = fact.person, let date = fact.dateValue else { return }
        let title = fact.value.isEmpty ? "Important date" : fact.value
        let record = ImportantDate(title: title, date: date, person: person)
        record.sourceCaptureUUID = fact.sourceCaptureUUID
        context.insert(record)
        NotificationService.shared.schedule(importantDate: record)
        fact.status = .superseded
        fact.markUserEdited()
    }

    /// Promotes a `.reminderSuggestion` fact into a real, scheduled
    /// `Reminder` once the user supplies a date it couldn't resolve on its
    /// own (see `CaptureProcessor.applyReminders`, which never invents one).
    static func schedule(_ fact: MemoryFact, dueDate: Date, context: ModelContext) {
        guard fact.type == .reminderSuggestion else { return }
        let reminder = Reminder(title: fact.value, dueDate: dueDate, type: .followUp, person: fact.person)
        reminder.sourceCaptureUUID = fact.sourceCaptureUUID
        context.insert(reminder)
        NotificationService.shared.schedule(reminder: reminder)
        fact.status = .superseded
        fact.markUserEdited()
    }

    /// Assigns an unattributed fact to a person after the fact — the
    /// correction path for "the user must be able to assign an
    /// unattributed fact later".
    static func assign(_ fact: MemoryFact, to person: Person) {
        fact.person = person
        fact.markUserEdited()
    }
}
