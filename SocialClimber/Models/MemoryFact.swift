import Foundation
import SwiftData
import SwiftUI

/// What kind of thing an automatically-extracted fact describes.
enum MemoryFactType: String, Codable, CaseIterable, Identifiable {
    case interest
    case dislike
    case schoolOrWork
    case location
    case family
    case personality
    case giftIdea
    case commitment
    case importantDate
    /// An explicit "remind me…" instruction with no resolvable date. Never
    /// scheduled automatically; the user can give it a date later, which
    /// promotes it into a real `Reminder` (see `MemoryFactPromotion`).
    case reminderSuggestion
    case general

    var id: String { rawValue }

    var label: String {
        switch self {
        case .interest: "Interest"
        case .dislike: "Dislike"
        case .schoolOrWork: "School / Work"
        case .location: "Location"
        case .family: "Family"
        case .personality: "Personality"
        case .giftIdea: "Gift idea"
        case .commitment: "Commitment"
        case .importantDate: "Important date"
        case .reminderSuggestion: "Reminder"
        case .general: "Fact"
        }
    }

    var icon: String {
        switch self {
        case .interest: "heart"
        case .dislike: "hand.thumbsdown"
        case .schoolOrWork: "building.2"
        case .location: "mappin.and.ellipse"
        case .family: "figure.2.and.child.holdinghands"
        case .personality: "brain.head.profile"
        case .giftIdea: "gift"
        case .commitment: "checkmark.seal"
        case .importantDate: "calendar"
        case .reminderSuggestion: "bell.badge"
        case .general: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .interest: .green
        case .dislike: .red
        case .schoolOrWork: .brown
        case .location: .teal
        case .family: .orange
        case .personality: .indigo
        case .giftIdea: .purple
        case .commitment: .blue
        case .importantDate: .orange
        case .reminderSuggestion: .blue
        case .general: .gray
        }
    }
}

/// Whether a fact is currently believed, merely suggested, or dead.
enum MemoryFactStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case suggested
    case rejected
    case superseded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active: "Active"
        case .suggested: "Suggested"
        case .rejected: "Rejected"
        case .superseded: "Superseded"
        }
    }
}

/// Where a fact's current state came from, tracked independently of
/// `status` so reprocessing can tell "the machine produced this and nothing
/// has touched it since" (safe to leave alone or refresh) apart from "a
/// person deliberately confirmed/edited/rejected this" (must never be
/// silently overwritten by automatic reprocessing).
enum MemoryFactOrigin: String, Codable {
    case machine
    case userConfirmed
    case userEdited
    case userRejected
}

/// One evidence-linked fact Social Climber learned about a person from a
/// capture ("applying to Stripe", "moving to New York in September").
/// Unlike the old flow, which flattened AI suggestions directly into
/// `Person.interests`/`personalityNotes` and therefore *required* a review
/// screen, facts live beside the profile, keep their provenance (which
/// capture and interaction produced them), and can be individually opened,
/// rejected, corrected, or deleted at any time. High-confidence facts are
/// `active` automatically; shakier ones stay `suggested`. Manually-entered
/// profile fields are never touched.
///
/// Attribution: `person` is the one confidently-named person this fact is
/// about, or `nil` when the capture's text didn't clearly name anyone (an
/// "unattributed" fact, still linked to its capture/interaction, and
/// assignable to a person later). A fact that applies to *several* named
/// people is represented as separate `MemoryFact` rows, one per person
/// (same value/type/source, different `person`), rather than a single
/// fact fanned out across a list; this keeps `Person.memoryFacts` a
/// simple, correct, queryable inverse relationship for every person it's
/// about, with no separate multi-person schema needed.
@Model
final class MemoryFact {
    var typeRaw: String = MemoryFactType.general.rawValue
    var value: String = ""
    var dateValue: Date?
    var confidence: Double = 0.5
    var statusRaw: String = MemoryFactStatus.suggested.rawValue
    var originRaw: String = MemoryFactOrigin.machine.rawValue
    /// The capture this fact was extracted from; lets the UI show the
    /// source and lets undo remove exactly what one capture produced.
    var sourceCaptureUUID: UUID?
    /// The specific interaction this fact was extracted alongside, when
    /// the capture successfully resolved one. Independent of
    /// `sourceCaptureUUID`: a fact can point at its interaction even if the
    /// interaction is later found without needing the original capture.
    var sourceInteractionUUID: UUID?
    var createdAt: Date = Date()
    var rejectedAt: Date?

    var person: Person?

    init(
        type: MemoryFactType,
        value: String,
        person: Person?,
        confidence: Double = 0.5,
        status: MemoryFactStatus = .suggested,
        dateValue: Date? = nil,
        sourceCaptureUUID: UUID? = nil,
        sourceInteractionUUID: UUID? = nil,
        origin: MemoryFactOrigin = .machine
    ) {
        self.typeRaw = type.rawValue
        self.value = value
        self.person = person
        self.confidence = confidence
        self.statusRaw = status.rawValue
        self.dateValue = dateValue
        self.sourceCaptureUUID = sourceCaptureUUID
        self.sourceInteractionUUID = sourceInteractionUUID
        self.originRaw = origin.rawValue
        self.createdAt = .now
    }

    var type: MemoryFactType {
        get { MemoryFactType(rawValue: typeRaw) ?? .general }
        set { typeRaw = newValue.rawValue }
    }

    var status: MemoryFactStatus {
        get { MemoryFactStatus(rawValue: statusRaw) ?? .suggested }
        set {
            statusRaw = newValue.rawValue
            if newValue == .rejected {
                rejectedAt = .now
                origin = .userRejected
            } else if newValue == .active, origin == .machine {
                origin = .userConfirmed
            }
        }
    }

    var origin: MemoryFactOrigin {
        get { MemoryFactOrigin(rawValue: originRaw) ?? .machine }
        set { originRaw = newValue.rawValue }
    }

    /// True once a person has explicitly confirmed, edited, or rejected
    /// this fact. Reprocessing must never overwrite or resurrect a fact
    /// once this is true.
    var isUserTouched: Bool { origin != .machine }

    /// Facts that should surface in profiles, briefs, search, and AI context.
    var isVisible: Bool { status == .active || status == .suggested }

    /// True for values automatic extraction produced that carry no real
    /// signal: a bare generic word ("education", "life"), just the person's
    /// own name, a "Name: …" fragment, or something too short to mean
    /// anything. These are the "cooked" rows that pile up in Learned
    /// Automatically, so every surface reading `visibleFacts` filters them
    /// out and the capture pipeline skips creating them. A fact a person
    /// has explicitly confirmed or edited is always kept, on the assumption
    /// that a human vouched for it.
    var isLowQuality: Bool {
        guard !isUserTouched else { return false }
        let names = [person?.name, person?.firstName, person?.nickname]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return MemoryFact.isLowQualityValue(value, type: type, ownerNames: names)
    }

    /// Value-level junk heuristic, usable before a `MemoryFact` exists so
    /// the capture pipeline can skip storing noise in the first place.
    static func isLowQualityValue(_ raw: String, type: MemoryFactType, ownerNames: [String]) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return true }
        let lower = trimmed.lowercased()

        // Nothing but the person's own name.
        if ownerNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return true
        }

        switch type {
        case .interest, .dislike, .general:
            // Single bare word from a grab-bag of category labels that say
            // nothing specific about the person.
            let generic: Set<String> = [
                "education", "school", "work", "job", "career", "life",
                "stuff", "things", "thing", "misc", "general", "other",
                "hobby", "hobbies", "interest", "interests", "food", "music",
                "sports", "sport", "people", "friend", "friends"
            ]
            if generic.contains(lower) { return true }
            // A lone very short token isn't a fact worth surfacing.
            if !trimmed.contains(" ") && trimmed.count < 4 { return true }
            return false
        case .reminderSuggestion, .commitment:
            // "Tony 杨: follow up buddy" and similar: the extractor jammed a
            // name label in front of a fragment. A real instruction never
            // starts with the contact's own name and a colon.
            for name in ownerNames where lower.hasPrefix(name.lowercased() + ":") {
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Marks this fact as edited by the user (value/date/attribution
    /// correction), distinct from a simple confirm/reject.
    func markUserEdited() {
        origin = .userEdited
    }
}
