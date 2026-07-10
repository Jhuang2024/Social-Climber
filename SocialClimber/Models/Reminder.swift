import Foundation
import SwiftData

@Model
final class Reminder {
    var title: String = ""
    var dueDate: Date = Date()
    var typeRaw: String = ReminderType.custom.rawValue
    var completed: Bool = false
    var notes: String = ""
    var notificationID: String?
    /// Set once completing this reminder has auto-logged an interaction
    /// (see `ReminderRowView`), so toggling it complete/incomplete/complete
    /// again never logs a duplicate.
    var autoLoggedInteraction: Bool = false
    /// UUID of the `CapturedMemory` that automatically created this
    /// reminder, if any (see `Interaction.sourceCaptureUUID`).
    var sourceCaptureUUID: UUID?
    var createdAt: Date = Date()

    var person: Person?

    init(
        title: String,
        dueDate: Date,
        type: ReminderType = .custom,
        person: Person? = nil,
        notes: String = ""
    ) {
        self.title = title
        self.dueDate = dueDate
        self.typeRaw = type.rawValue
        self.person = person
        self.notes = notes
        self.createdAt = .now
    }

    var type: ReminderType {
        get { ReminderType(rawValue: typeRaw) ?? .custom }
        set { typeRaw = newValue.rawValue }
    }

    var isOverdue: Bool { !completed && dueDate < Calendar.current.startOfDay(for: .now) }
}
