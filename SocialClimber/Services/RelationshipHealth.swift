import Foundation

/// Pure logic for deriving relationship status from a person's data.
///
/// Every entry point takes an explicit `now`. That matters for the Social
/// Health trend chart, which replays the score at ~60 past dates: reading
/// "today" from the system clock inside these helpers made every historical
/// point use today's cadence and today's contact dates, which is a large
/// part of why the chart drew a flat line.
enum RelationshipHealth {
    /// How often (in days) this person should be contacted, unless the
    /// person has an explicit cadence override.
    ///
    /// The base tier comes from *priority*: how much you want to actively
    /// invest in this relationship, not closeness, since a relationship
    /// you're already close to tends to sustain itself. Closeness only ever
    /// loosens the cadence from there (a very close relationship should
    /// rarely need a nudge), it never tightens it. Finally, when there's
    /// enough real history to see how this person actually communicates,
    /// the cadence is stretched to comfortably outlast their own natural
    /// rhythm: someone you already text every few days shouldn't be
    /// flagged as "due" between those texts. Anchor cadences are
    /// user-configurable in Settings.
    static func expectedCadenceDays(for person: Person, now: Date = .now) -> Int {
        if let custom = person.checkInCadenceDays, custom > 0 { return custom }
        let defaults = UserDefaults.standard
        func stored(_ key: String, _ fallback: Double) -> Double {
            let value = defaults.integer(forKey: key)
            return value > 0 ? Double(value) : fallback
        }
        // Deliberately generous: the app should feel like it rarely
        // interrupts, not like another daily chore.
        let close = stored("defaultCadenceClose", 21)
        let regular = stored("defaultCadenceRegular", 60)
        let distant = stored("defaultCadenceDistant", 120)
        let base: Double = switch person.priority {
        case 5: close
        case 4: (close + regular) / 2
        case 3: regular
        case 2: (regular + distant) / 2
        default: distant
        }

        // Only loosens (closeness 4-5); closeness 3 and below leaves the
        // priority-driven base untouched rather than tightening it further.
        let closenessFactor = 1.0 + Double(max(0, person.closeness - 3)) * 0.35
        var cadence = base * closenessFactor

        // Someone who naturally communicates often shouldn't "reappear" as
        // due between their own normal beats: stretch the cadence to
        // comfortably outlast their real rhythm.
        if let rhythm = naturalRhythmDays(for: person, now: now) {
            cadence = max(cadence, rhythm * 2.5)
        }

        return max(10, Int(cadence))
    }

    /// The typical number of days between this person's recent interactions:
    /// how often they naturally come up, independent of the configured
    /// cadence. `nil` when there isn't enough recent history to infer a
    /// rhythm (fewer than 3 interactions in the year before `now`), so the
    /// priority/closeness-derived cadence is used as-is.
    static func naturalRhythmDays(for person: Person, sampleSize: Int = 8, now: Date = .now) -> Double? {
        let recentDates = person.interactions
            .map(\.date)
            .filter { $0 <= now && ScoreCurves.days(from: $0, to: now) <= 365 }
            .sorted(by: >)
            .prefix(sampleSize)
        guard recentDates.count >= 3 else { return nil }
        let gaps = zip(recentDates, recentDates.dropFirst())
            .map { $0.timeIntervalSince($1) / 86400 }
            .filter { $0 > 0 }
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    /// The most recent moment this person was contacted as of `now`, taking
    /// both the cached "last…" fields and the logged timeline into account.
    /// Anything dated after `now` is ignored so a historical replay can't
    /// see the future.
    static func lastContactDate(for person: Person, now: Date = .now) -> Date? {
        let cached = [person.lastContactedAt, person.lastMetAt, person.lastMessagedAt, person.lastCalledAt]
            .compactMap { $0 }
        let logged = person.interactions.map(\.date)
        return (cached + logged).filter { $0 <= now }.max()
    }

    static func daysSinceContact(for person: Person, now: Date = .now) -> Int? {
        guard let latest = lastContactDate(for: person, now: now) else { return nil }
        return Int(ScoreCurves.days(from: latest, to: now))
    }

    static func status(for person: Person, now: Date = .now) -> RelationshipStatus {
        if person.isArchived { return .archived }

        let cadence = Double(expectedCadenceDays(for: person, now: now))
        guard let latest = lastContactDate(for: person, now: now) else {
            // Never contacted: nudge, don't panic.
            return .checkInSoon
        }
        var ratio = ScoreCurves.days(from: latest, to: now) / cadence

        // Unresolved follow-ups make the relationship need attention sooner.
        let openFollowUps = person.reminders.filter { !$0.completed && $0.type == .followUp }.count
            + person.interactions.filter { $0.followUpNeeded && $0.date <= now }.count
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
}
