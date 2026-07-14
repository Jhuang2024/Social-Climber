import Foundation
import SwiftData

/// Builds the `SocialClimberBriefFeed` snapshot from live SwiftData records.
/// A pure, read-only projection: it fetches, summarizes, and returns a
/// value. Writing the file — and the sharing gate — stays in
/// `CrossAppIntegrationManager`, so this type never needs to know where the
/// feed lands or whether sharing is even on.
///
/// Everything here is best-effort and fail-silent: a failed fetch reads as
/// "no records," never an error, because the feed must never affect Social
/// Climber's own behavior. All ordering is deterministic (explicit sorts
/// with stable tie-breaks) so consecutive writes of the same data produce
/// the same bytes.
enum BriefFeedPublisher {
    /// How far back the day-summary section looks. Brief only ever renders
    /// "yesterday," with a fallback to the most recent entry within 3 days,
    /// so anything older would be dead weight in the file.
    private static let dayLookback = 3
    /// The reminder window covers today, tomorrow, and the day after
    /// ("due within 2 days"), counted in local calendar days; everything
    /// overdue is included regardless of age.
    private static let reminderWindowDays = 3
    private static let maxLinesPerDay = 8
    private static let maxReminders = 12
    /// Check-in nudges are advisory, not real dated reminders: a couple of
    /// the most-overdue people is a useful prompt, twelve is a guilt trip.
    private static let maxCheckIns = 3

    /// The contract's local-day key: fixed "yyyy-MM-dd" pattern with the
    /// POSIX locale (so a 12/24-hour or non-Gregorian user setting can
    /// never bend the pattern) but the *current* calendar and timezone,
    /// because the whole point is that Brief and Social Climber agree on
    /// what "yesterday" meant to the user.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Builds the full feed from whatever is currently in the store.
    static func makeFeed(context: ModelContext, now: Date = .now) -> SocialClimberBriefFeed {
        let people = fetchAll(Person.self, from: context)
        let interactions = fetchAll(Interaction.self, from: context)
        let events = fetchAll(Event.self, from: context)
        let reminders = fetchAll(Reminder.self, from: context)
        let importantDates = fetchAll(ImportantDate.self, from: context)
        let captures = fetchAll(CapturedMemory.self, from: context)
        let voiceNotes = fetchAll(VoiceNote.self, from: context)
        let followerEvents = fetchAll(FollowerEvent.self, from: context)

        return SocialClimberBriefFeed(
            generatedAt: now,
            days: dayEntries(
                people: people,
                interactions: interactions,
                events: events,
                captures: captures,
                voiceNotes: voiceNotes,
                followerEvents: followerEvents,
                now: now
            ),
            reminders: reminderEntries(
                people: people,
                reminders: reminders,
                importantDates: importantDates,
                events: events,
                now: now
            )
        )
    }

    // MARK: - Day summaries

    private static func dayEntries(
        people: [Person],
        interactions: [Interaction],
        events: [Event],
        captures: [CapturedMemory],
        voiceNotes: [VoiceNote],
        followerEvents: [FollowerEvent],
        now: Date
    ) -> [SocialClimberBriefFeed.Day] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        var days: [SocialClimberBriefFeed.Day] = []
        for offset in 0..<dayLookback {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let lines = lines(
                for: day,
                people: people,
                interactions: interactions,
                events: events,
                captures: captures,
                voiceNotes: voiceNotes,
                followerEvents: followerEvents,
                now: now
            )
            // A day with nothing to say is omitted entirely, per the
            // contract; Brief falls back to the most recent present day.
            guard !lines.isEmpty else { continue }
            days.append(SocialClimberBriefFeed.Day(
                date: dayKeyFormatter.string(from: day),
                lines: Array(lines.prefix(maxLinesPerDay))
            ))
        }
        return days
    }

    /// All of one local day's summary lines, most important category first
    /// (interactions, then events, then everything peripheral), so the
    /// per-day cap always trims from the bottom.
    private static func lines(
        for day: Date,
        people: [Person],
        interactions: [Interaction],
        events: [Event],
        captures: [CapturedMemory],
        voiceNotes: [VoiceNote],
        followerEvents: [FollowerEvent],
        now: Date
    ) -> [String] {
        let calendar = Calendar.current
        var lines: [String] = []

        // 1. Interactions logged that day. A short day reads as one line
        // per interaction, in the order things happened; a busy day
        // collapses into a single count-plus-names line so it can't crowd
        // out everything else below.
        let dayInteractions = interactions
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
        if dayInteractions.count > 3 {
            var seen = Set<String>()
            var names: [String] = []
            for interaction in dayInteractions {
                for person in interaction.people where seen.insert(person.firstName).inserted {
                    names.append(person.firstName)
                }
            }
            var line = "Logged \(dayInteractions.count) interactions"
            if !names.isEmpty { line += " — \(nameList(names))" }
            lines.append(line)
        } else {
            lines.append(contentsOf: dayInteractions.map { line(for: $0) })
        }

        // 2. Events that actually happened. An event later today isn't
        // activity yet — it shows up in the reminders section instead, so
        // the same event never appears in both places at once.
        let dayEvents = events
            .filter { calendar.isDate($0.date, inSameDayAs: day) && $0.date <= now }
            .sorted { $0.date < $1.date }
        lines.append(contentsOf: dayEvents.map { line(for: $0) })

        // 3. People added that day.
        let added = people
            .filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt < $1.createdAt }
        if !added.isEmpty {
            let names = added.map(\.firstName)
            if added.count > 3 {
                lines.append("Added \(added.count) people — \(nameList(names))")
            } else {
                lines.append("Added \(names.joined(separator: ", ")) to your people")
            }
        }

        // 4. Captures that finished processing. Keyed off `capturedAt`
        // (when the memory happened, which is what a recap is about), and
        // only `.processed` — a still-queued or failed capture isn't a
        // remembered memory yet.
        let dayCaptures = captures
            .filter { $0.status == .processed && calendar.isDate($0.capturedAt, inSameDayAs: day) }
        if dayCaptures.count == 1, let capture = dayCaptures.first, !capture.title.isEmpty {
            lines.append("Captured “\(capture.title)”")
        } else if !dayCaptures.isEmpty {
            lines.append("Captured \(dayCaptures.count) \(dayCaptures.count == 1 ? "memory" : "memories")")
        }

        // 5. Long-form voice notes (the quick voice-capture flow already
        // surfaces through captures above).
        let dayNotes = voiceNotes.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
        if dayNotes.count == 1, let note = dayNotes.first {
            let names = note.people.map(\.firstName)
            lines.append(names.isEmpty
                ? "Recorded a voice note"
                : "Recorded a voice note about \(nameList(names))")
        } else if !dayNotes.isEmpty {
            lines.append("Recorded \(dayNotes.count) voice notes")
        }

        // 6. Instagram follower movement, if a sync landed events on this
        // day. Only the two directions about *you* — who followed or
        // unfollowed you — matter in a morning recap.
        let dayFollowerEvents = followerEvents.filter { calendar.isDate($0.date, inSameDayAs: day) }
        let gained = dayFollowerEvents.filter { $0.kind == .gainedFollower }.count
        let lost = dayFollowerEvents.filter { $0.kind == .lostFollower }.count
        if gained > 0 || lost > 0 {
            var parts: [String] = []
            if gained > 0 { parts.append("\(gained) new follower\(gained == 1 ? "" : "s")") }
            if lost > 0 { parts.append("\(lost) unfollow\(lost == 1 ? "" : "s")") }
            lines.append("Instagram: " + parts.joined(separator: ", "))
        }

        return lines
    }

    /// One interaction as a name-forward line, e.g.
    /// "Called Sarah — went well". Sentiment only gets a tail when it says
    /// something (neutral is the default, so spelling it out is noise);
    /// a neutral interaction falls back to its own summary/note preview,
    /// which is usually the more interesting detail anyway.
    private static func line(for interaction: Interaction) -> String {
        let names = interaction.people.map(\.firstName)
        let subject = names.isEmpty ? "someone" : nameList(names)
        var line: String = switch interaction.type {
        case .inPerson: "Saw \(subject)"
        case .call: "Called \(subject)"
        case .videoCall: "Video call with \(subject)"
        case .message, .socialMedia: "Messaged \(subject)"
        case .email: "Emailed \(subject)"
        case .event: "Saw \(subject) at an event"
        case .voiceNote: "Voice note about \(subject)"
        case .favor, .intro, .other: "Caught up with \(subject) (\(interaction.type.label.lowercased()))"
        }
        switch interaction.sentiment {
        case .great: line += " — went great"
        case .good: line += " — went well"
        case .bad: line += " — felt off"
        case .neutral:
            let preview = interaction.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                line += " — \(preview.count > 60 ? String(preview.prefix(60)) + "…" : preview)"
            }
        }
        return line
    }

    /// One attended event as a line, e.g. "Climbing night with Sarah, Mike"
    /// or "Company mixer (12 people)" once naming everyone stops scaling.
    private static func line(for event: Event) -> String {
        let name = event.name.isEmpty ? "Untitled event" : event.name
        switch event.attendees.count {
        case 0: return name
        case 1...3: return "\(name) with \(event.attendeeNames)"
        default: return "\(name) (\(event.attendees.count) people)"
        }
    }

    // MARK: - Reminders

    private static func reminderEntries(
        people: [Person],
        reminders: [Reminder],
        importantDates: [ImportantDate],
        events: [Event],
        now: Date
    ) -> [SocialClimberBriefFeed.ReminderEntry] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: reminderWindowDays, to: startOfToday) else {
            return []
        }

        var entries: [SocialClimberBriefFeed.ReminderEntry] = []

        // 1. Explicit reminders: everything overdue plus anything due
        // inside the window. Archived people's reminders are skipped, same
        // rule as the peer-bridge snapshot. Due dates come from a date-only
        // picker, so the time-of-day component is incidental — hence
        // `isAllDay: true`.
        for reminder in reminders {
            guard !reminder.completed, reminder.dueDate < windowEnd else { continue }
            guard !(reminder.person?.isArchived ?? false) else { continue }
            var title = reminder.title.isEmpty ? reminder.type.label : reminder.title
            // Person-prefixed so the brief reads name-forward, unless the
            // title already names them ("Text Sarah back" shouldn't become
            // "Sarah — Text Sarah back").
            if let person = reminder.person, !person.firstName.isEmpty,
               !title.localizedCaseInsensitiveContains(person.firstName) {
                title = "\(person.firstName) — \(title)"
            }
            let notes = reminder.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(SocialClimberBriefFeed.ReminderEntry(
                id: stableID(reminder.persistentModelID),
                title: title,
                detail: notes.isEmpty ? nil : notes,
                dueDate: reminder.dueDate,
                isAllDay: true,
                overdue: reminder.dueDate < startOfToday
            ))
        }

        // 2. Birthdays. These live on `Person.birthday` (the same source
        // the dashboard's Upcoming card uses), not only on `ImportantDate`,
        // so both are checked — with dedup below so a person who has both
        // doesn't appear twice.
        var birthdayPersonIDs = Set<UUID>()
        for person in people where !person.isArchived {
            guard let next = person.nextBirthday, next >= startOfToday, next < windowEnd else { continue }
            birthdayPersonIDs.insert(person.uuid)
            entries.append(SocialClimberBriefFeed.ReminderEntry(
                id: "birthday-\(person.uuid.uuidString)",
                title: "\(person.firstName)'s birthday",
                detail: nil,
                dueDate: calendar.startOfDay(for: next),
                isAllDay: true,
                overdue: false
            ))
        }

        // 3. Important dates (anniversaries, one-offs) falling in the window.
        for importantDate in importantDates {
            guard let next = importantDate.nextOccurrence, next >= startOfToday, next < windowEnd else { continue }
            guard !(importantDate.person?.isArchived ?? false) else { continue }
            // Skip an ImportantDate that duplicates a birthday already
            // emitted from `Person.birthday` above.
            if let person = importantDate.person,
               birthdayPersonIDs.contains(person.uuid),
               importantDate.title.localizedCaseInsensitiveContains("birthday") {
                continue
            }
            var title = importantDate.title.isEmpty ? "Important date" : importantDate.title
            if let person = importantDate.person, !person.firstName.isEmpty,
               !title.localizedCaseInsensitiveContains(person.firstName) {
                title = "\(person.firstName) — \(title)"
            }
            let notes = importantDate.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(SocialClimberBriefFeed.ReminderEntry(
                id: stableID(importantDate.persistentModelID),
                title: title,
                detail: notes.isEmpty ? nil : notes,
                dueDate: calendar.startOfDay(for: next),
                isAllDay: true,
                overdue: false
            ))
        }

        // 4. Events starting in the window. Events have a real start time
        // (their editor picks date and hour), so these are the one entry
        // kind where Brief should show the clock.
        for event in events {
            guard event.date >= now, event.date < windowEnd else { continue }
            let attendees = event.attendeeNames
            let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(SocialClimberBriefFeed.ReminderEntry(
                id: stableID(event.persistentModelID),
                title: event.name.isEmpty ? "Untitled event" : event.name,
                detail: attendees.isEmpty ? (location.isEmpty ? nil : location) : "With \(attendees)",
                dueDate: event.date,
                isAllDay: false,
                overdue: false
            ))
        }

        // 5. Check-in nudges, reusing `RelationshipHealth`'s status verdict
        // (via `Person.status`) rather than re-deriving cadence math here.
        // `.checkInSoon` and `.goingQuiet` both warrant a morning nudge;
        // `.dormant` is deliberately excluded — resurfacing a long-gone
        // contact every single morning is noise, not help.
        let checkIns = people
            .filter {
                let status = $0.status
                return status == .checkInSoon || status == .goingQuiet
            }
            .sorted { lhs, rhs in
                // Most quiet first; never-contacted people (no date at all)
                // sort last since there's no streak to report.
                let lhsDays = RelationshipHealth.daysSinceContact(for: lhs) ?? -1
                let rhsDays = RelationshipHealth.daysSinceContact(for: rhs) ?? -1
                if lhsDays != rhsDays { return lhsDays > rhsDays }
                return lhs.name < rhs.name
            }
            .prefix(maxCheckIns)
        for person in checkIns {
            var title = "Check in with \(person.firstName)"
            // The quiet streak only reads as a reason once it's at least a
            // week; a person flagged early (e.g. for an upcoming birthday)
            // just gets the plain nudge.
            if let days = RelationshipHealth.daysSinceContact(for: person), days >= 7 {
                title += " (\(quietLabel(days: days)))"
            }
            entries.append(SocialClimberBriefFeed.ReminderEntry(
                id: "checkin-\(person.uuid.uuidString)",
                title: title,
                detail: nil,
                dueDate: startOfToday,
                isAllDay: true,
                overdue: false
            ))
        }

        // Overdue first, then soonest due; ties broken by title then id so
        // consecutive writes of the same data order identically.
        entries.sort { lhs, rhs in
            if lhs.overdue != rhs.overdue { return lhs.overdue }
            if lhs.dueDate != rhs.dueDate { return lhs.dueDate < rhs.dueDate }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
        return Array(entries.prefix(maxReminders))
    }

    // MARK: - Helpers

    /// A failed fetch reads as "no records": the feed is a best-effort
    /// projection and must never surface an error of its own.
    private static func fetchAll<T: PersistentModel>(_ type: T.Type, from context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    /// The same opaque, compare-only external ID scheme the peer-bridge
    /// snapshot uses (`SocialClimberPublicContext`): stable across writes,
    /// never parsed by the reader.
    private static func stableID(_ id: PersistentIdentifier) -> String {
        String(describing: id)
    }

    /// "Sarah, Mike, +3 more" — every name up to the limit, then a count,
    /// so a big group never turns a summary line into a paragraph.
    private static func nameList(_ names: [String], limit: Int = 3) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        let shown = names.prefix(limit - 1)
        return shown.joined(separator: ", ") + ", +\(names.count - shown.count) more"
    }

    /// "12 days quiet" / "3 weeks quiet" / "4 months quiet" — coarse on
    /// purpose; the point is a felt duration, not bookkeeping.
    private static func quietLabel(days: Int) -> String {
        switch days {
        case ..<14: "\(days) days quiet"
        case ..<70: "\(days / 7) weeks quiet"
        default: "\(days / 30) months quiet"
        }
    }
}
