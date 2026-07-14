import Foundation

/// The "brief feed" snapshot Social Climber publishes for Brief, the
/// morning-briefing app: a few days of human-readable activity summaries
/// plus the social reminders that matter over the next couple of days.
///
/// Encode-only: Social Climber writes this file and never reads it back, so
/// there is no decoding counterpart here. The wire contract lives in the
/// Brief repo's `LINKED_APPS.md` (`socialclimber_brief_feed_v1.json`,
/// schema v1) and changes must stay strictly additive — Brief decodes
/// defensively and treats unknown fields as noise, but renaming or removing
/// a key would silently blank the section in the user's morning brief.
///
/// Unlike `SocialClimberPublicContext` (deliberately anonymized, because a
/// *different* app consumes it), this feed is written for the user's own
/// eyes in their own brief, so it carries real detail: names, interaction
/// types, event titles, and reminder text.
struct SocialClimberBriefFeed: Codable, Equatable {
    /// One local calendar day's worth of activity, already rendered into
    /// short display lines so Brief never has to interpret Social Climber's
    /// domain — it just prints them.
    struct Day: Codable, Equatable {
        /// Local calendar day as "yyyy-MM-dd" (see
        /// `BriefFeedPublisher.dayKeyFormatter`), *not* an instant: Brief
        /// matches it against its own notion of "yesterday" in the same
        /// timezone the user lives in.
        var date: String
        /// Up to 8 summary lines, most important first.
        var lines: [String]
    }

    /// One "today" item: an explicit reminder, a birthday/important date,
    /// an upcoming event, or a check-in nudge, all flattened into the same
    /// shape so Brief renders them as a single list.
    struct ReminderEntry: Codable, Equatable {
        /// Stable across writes so Brief can deduplicate/diff between
        /// generations; opaque, never parsed by the reader.
        var id: String
        var title: String
        /// Optional secondary text; omitted from the JSON entirely when nil
        /// (JSONEncoder skips nil optionals), per the contract.
        var detail: String?
        var dueDate: Date
        /// True when the due date is a day, not a moment — Brief then hides
        /// the time component.
        var isAllDay: Bool
        /// True when past due and still incomplete at write time.
        var overdue: Bool
    }

    var app: String = "SocialClimber"
    var schemaVersion: Int = 1
    var generatedAt: Date
    /// Up to 3 most recent local days that had any activity, newest first.
    var days: [Day]
    /// Overdue first, then soonest due; capped at 12.
    var reminders: [ReminderEntry]
}
