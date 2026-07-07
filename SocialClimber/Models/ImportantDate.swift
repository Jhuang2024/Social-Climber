import Foundation
import SwiftData

@Model
final class ImportantDate {
    var title: String = ""
    var date: Date = Date()
    var repeatsYearly: Bool = true
    var notes: String = ""
    var notificationID: String?
    var createdAt: Date = Date()

    var person: Person?

    init(
        title: String,
        date: Date,
        repeatsYearly: Bool = true,
        person: Person? = nil,
        notes: String = ""
    ) {
        self.title = title
        self.date = date
        self.repeatsYearly = repeatsYearly
        self.person = person
        self.notes = notes
        self.createdAt = .now
    }

    /// The next time this date matters: the stored date if upcoming/one-off,
    /// or the next yearly anniversary.
    var nextOccurrence: Date? {
        if repeatsYearly { return date.nextYearlyOccurrence }
        return date.daysFromNow >= 0 ? date : nil
    }
}
