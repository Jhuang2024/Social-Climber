import Foundation
import SwiftData
import SwiftUI

/// What kind of thing actually happened. Deliberately a short list of
/// categories that a person would recognize as "something happened", rather
/// than a taxonomy of everything a conversation can contain.
enum LifeEventKind: String, Codable, CaseIterable, Identifiable {
    case education
    case career
    case move
    case health
    case relationship
    case loss
    case achievement
    case conflict
    case milestone
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .education: "School"
        case .career: "Work"
        case .move: "Moved"
        case .health: "Health"
        case .relationship: "Relationship"
        case .loss: "Loss"
        case .achievement: "Achievement"
        case .conflict: "Fallout"
        case .milestone: "Milestone"
        case .other: "Event"
        }
    }

    var icon: String {
        switch self {
        case .education: "graduationcap.fill"
        case .career: "briefcase.fill"
        case .move: "shippingbox.fill"
        case .health: "cross.case.fill"
        case .relationship: "heart.fill"
        case .loss: "leaf.fill"
        case .achievement: "trophy.fill"
        case .conflict: "exclamationmark.bubble.fill"
        case .milestone: "flag.fill"
        case .other: "sparkle"
        }
    }

    var color: Color {
        switch self {
        case .education: .indigo
        case .career: .brown
        case .move: .teal
        case .health: .red
        case .relationship: .pink
        case .loss: .gray
        case .achievement: .yellow
        case .conflict: .orange
        case .milestone: .purple
        case .other: .blue
        }
    }
}

/// One thing that actually happened to the user or to someone they track,
/// learned from a conversation they captured or imported.
///
/// This is the "Past Events" record, and it is deliberately *not* a log of
/// everything said. An interaction already records that a conversation
/// happened and `MemoryFact` already records durable traits ("into
/// climbing"). A `LifeEvent` is the narrower thing in between: a dated,
/// consequential change of state — got into a school, started a job, moved
/// city, broke up, someone died, a falling-out. Plans and hypotheticals are
/// not events; they stay reminders. The extraction side is held to the same
/// bar (see `AIExtraction.pastEvents` and `LifeEventFilter`), because a
/// feed that fills with "talked about food" is worse than no feed.
@Model
final class LifeEvent {
    var uuid: UUID = UUID()
    var title: String = ""
    var detail: String = ""
    /// When it happened, as best as the source could say — not when it was
    /// captured. Falls back to the capture date when the text gives nothing.
    var date: Date = Date()
    /// True when the date came from the capture rather than the text, so the
    /// UI can say "around" instead of implying a precise day.
    var isDateApproximate: Bool = false
    var kindRaw: String = LifeEventKind.other.rawValue
    /// 1–5. Only 3+ is surfaced by default; the bar for storing anything at
    /// all is already high, and this orders what shows first.
    var significance: Int = 3
    /// True when this happened to the user themselves rather than to a
    /// contact. Both belong in Past Events: "what's happened to you *and*
    /// your relationships".
    var aboutMe: Bool = false
    var confidence: Double = 0.5
    /// Set when the user removes an event from the feed. Kept rather than
    /// deleted so reprocessing the same capture can't resurrect it.
    var isDismissed: Bool = false
    /// True once a human edited or explicitly confirmed it, so automatic
    /// reprocessing leaves it alone.
    var isUserTouched: Bool = false
    var sourceCaptureUUID: UUID?
    var sourceInteractionUUID: UUID?
    var createdAt: Date = Date()

    /// Who it happened to. `nil` together with `aboutMe == true` means the
    /// user; `nil` with `aboutMe == false` should never be stored (see
    /// `CaptureProcessor.applyPastEvents`).
    var person: Person?

    init(
        title: String,
        detail: String = "",
        date: Date,
        isDateApproximate: Bool = false,
        kind: LifeEventKind = .other,
        significance: Int = 3,
        aboutMe: Bool = false,
        person: Person? = nil,
        confidence: Double = 0.5,
        sourceCaptureUUID: UUID? = nil,
        sourceInteractionUUID: UUID? = nil
    ) {
        self.uuid = UUID()
        self.title = title
        self.detail = detail
        self.date = date
        self.isDateApproximate = isDateApproximate
        self.kindRaw = kind.rawValue
        self.significance = min(5, max(1, significance))
        self.aboutMe = aboutMe
        self.person = person
        self.confidence = confidence
        self.sourceCaptureUUID = sourceCaptureUUID
        self.sourceInteractionUUID = sourceInteractionUUID
        self.createdAt = .now
    }

    var kind: LifeEventKind {
        get { LifeEventKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    /// "You" or the contact's first name: who this happened to.
    var subjectLabel: String {
        if aboutMe { return "You" }
        return person?.firstName ?? "Someone"
    }

    /// One line for the morning brief and the dashboard preview.
    var briefLine: String {
        aboutMe ? title : "\(subjectLabel): \(title)"
    }

    /// Stable identity for de-duplication across reprocessing and across two
    /// captures describing the same thing: same kind, same subject, same
    /// normalized wording.
    var dedupeKey: String {
        LifeEvent.dedupeKey(
            title: title,
            kind: kind,
            personUUID: person?.uuid,
            aboutMe: aboutMe
        )
    }

    static func dedupeKey(title: String, kind: LifeEventKind, personUUID: UUID?, aboutMe: Bool) -> String {
        let normalized = title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let subject = aboutMe ? "me" : (personUUID?.uuidString ?? "unknown")
        return "\(kind.rawValue)|\(subject)|\(normalized)"
    }
}
