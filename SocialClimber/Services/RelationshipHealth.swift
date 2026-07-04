import Foundation

/// Pure logic for deriving relationship status from a person's data.
enum RelationshipHealth {
    /// How often (in days) this person should be contacted, from closeness,
    /// adjusted by priority, unless the person has an explicit cadence.
    /// Anchor cadences are user-configurable in Settings.
    static func expectedCadenceDays(for person: Person) -> Int {
        if let custom = person.checkInCadenceDays, custom > 0 { return custom }
        let defaults = UserDefaults.standard
        func stored(_ key: String, _ fallback: Double) -> Double {
            let value = defaults.integer(forKey: key)
            return value > 0 ? Double(value) : fallback
        }
        let close = stored("defaultCadenceClose", 7)
        let regular = stored("defaultCadenceRegular", 30)
        let distant = stored("defaultCadenceDistant", 90)
        let base: Double = switch person.closeness {
        case 5: close
        case 4: (close + regular) / 2
        case 3: regular
        case 2: (regular + distant) / 2
        default: distant
        }
        // Higher priority tightens the cadence, lower loosens it.
        let factor = 1.0 - Double(person.priority - 3) * 0.15
        return max(3, Int(base * factor))
    }

    static func daysSinceContact(for person: Person) -> Int? {
        let dates = [person.lastContactedAt, person.lastMetAt, person.lastMessagedAt, person.lastCalledAt].compactMap { $0 }
        guard let latest = dates.max() else { return nil }
        return latest.daysAgo
    }

    static func status(for person: Person, now: Date = .now) -> RelationshipStatus {
        if person.isArchived { return .archived }

        let cadence = Double(expectedCadenceDays(for: person))
        guard let days = daysSinceContact(for: person) else {
            // Never contacted: nudge, don't panic.
            return .checkInSoon
        }
        var ratio = Double(days) / cadence

        // Unresolved follow-ups make the relationship need attention sooner.
        let openFollowUps = person.reminders.filter { !$0.completed && $0.type == .followUp }.count
            + person.interactions.filter(\.followUpNeeded).count
        ratio += Double(min(openFollowUps, 3)) * 0.15

        // An important date coming up in the next 2 weeks warrants a check-in.
        let upcomingDate = upcomingImportantDateWithin(days: 14, for: person)

        switch ratio {
        case ..<1.0: return upcomingDate ? .checkInSoon : .good
        case ..<1.75: return .checkInSoon
        case ..<3.5: return .goingQuiet
        default: return .dormant
        }
    }

    static func upcomingImportantDateWithin(days window: Int, for person: Person) -> Bool {
        if let next = person.nextBirthday, next.daysFromNow <= window { return true }
        return person.importantDates.contains { date in
            guard let next = date.nextOccurrence else { return false }
            return next.daysFromNow <= window
        }
    }

    /// 0...1 score used for sorting who most needs attention (lower = worse).
    static func score(for person: Person) -> Double {
        guard !person.isArchived else { return 1 }
        let cadence = Double(expectedCadenceDays(for: person))
        guard let days = daysSinceContact(for: person) else { return 0.5 }
        return max(0, 1.0 - Double(days) / (cadence * 4))
    }
}
