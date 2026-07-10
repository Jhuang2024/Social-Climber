import Foundation

/// An immutable, `Sendable` snapshot of exactly what `PersonResolver` needs
/// from a `Person`. Resolution runs off the main actor (see
/// `CaptureEngine`), so it can never touch live SwiftData model objects;
/// only these plain value-type copies, taken on the main actor right before
/// handing off.
struct PersonSnapshot: Sendable, Hashable {
    var id: UUID
    var name: String
    var nickname: String
    var firstName: String
    var contactMethodValues: [String]
    var lastContactedAt: Date?
    var isArchived: Bool
}

/// Resolves which known people one capture is about, returning ranked
/// candidates with confidence rather than a single optional guess.
///
/// Signals combined, strongest first: trusted context supplied by the entry
/// point (a profile, an event, an assignment) → exact full-name/nickname
/// matches → contact-method values → AI-mentioned names → unique first-name
/// matches, boosted by recency. Multiple plausible matches are never picked
/// silently: they come back as candidates and the capture goes to
/// Needs Context instead.
///
/// Operates entirely over `PersonSnapshot` values and returns `UUID`s, never
/// live `Person` objects, so it's safe to call from any actor (see
/// `CaptureEngine`); the caller re-fetches actual `Person`s by ID on the
/// actor that owns the `ModelContext`.
enum PersonResolver {

    struct Candidate: Sendable, Identifiable {
        let personID: UUID
        let score: Double
        var id: UUID { personID }
    }

    struct Resolution: Sendable {
        /// IDs of people confident enough to auto-attach.
        var matchedIDs: [UUID] = []
        /// Ranked alternatives when nothing (or nothing more) was certain.
        var candidates: [Candidate] = []
        /// Confidence of the weakest auto-attached match (1.0 for trusted).
        var confidence: Double = 0
        /// True when the capture should wait for the user to say who it was.
        var needsContext: Bool { matchedIDs.isEmpty }
    }

    /// Thresholds: at or above `autoSelect` a unique match attaches itself;
    /// between `candidate` and `autoSelect` it becomes a one-tap chip.
    private static let autoSelectThreshold = 0.75
    private static let candidateThreshold = 0.35

    static func resolve(
        text: String,
        trustedIDs: [UUID],
        trustedNames: [String],
        aiMentioned: [String],
        people: [PersonSnapshot]
    ) -> Resolution {
        var resolution = Resolution()
        let active = people.filter { !$0.isArchived }
        let lower = " " + text.lowercased() + " "

        // 1. Trusted context wins outright, confidence 1.0. IDs are
        //    authoritative: an ID that no longer resolves (the person was
        //    deleted since) is silently dropped rather than guessed by
        //    name, and names are consulted only when literally no ID was
        //    ever recorded (a defensive fallback, not the normal path).
        var matched: [PersonSnapshot] = []
        if !trustedIDs.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
            for id in trustedIDs {
                if let person = byID[id], !matched.contains(where: { $0.id == person.id }) {
                    matched.append(person)
                }
            }
        } else if !trustedNames.isEmpty {
            for name in trustedNames {
                if let person = active.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                    ?? active.first(where: { !$0.nickname.isEmpty && $0.nickname.caseInsensitiveCompare(name) == .orderedSame }) {
                    if !matched.contains(where: { $0.id == person.id }) { matched.append(person) }
                }
            }
        }
        if !matched.isEmpty {
            resolution.matchedIDs = matched.map(\.id)
            resolution.confidence = 1.0
            // Trusted context doesn't stop additional confident text matches
            // (e.g. "Met Daniel and Priya" from an event with both trusted
            // plus a third person named in text): fall through and merge.
        }

        // 2. Score every person against the text.
        var scored: [(person: PersonSnapshot, score: Double)] = []
        for person in active {
            if matched.contains(where: { $0.id == person.id }) { continue }
            var score = 0.0
            let fullName = person.name.lowercased()
            let nickname = person.nickname.lowercased()
            let firstName = person.firstName.lowercased()

            if !fullName.isEmpty, lower.contains(" \(fullName) ") || lower.contains(" \(fullName),") || lower.contains(" \(fullName).") || lower.contains(fullName) {
                score = max(score, 0.95)
            }
            if !nickname.isEmpty, CaptureParser.containsWord(nickname, in: lower) {
                score = max(score, 0.9)
            }
            if person.contactMethodValues.contains(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) {
                score = max(score, 0.9)
            }
            if score == 0, !firstName.isEmpty, firstName.count >= 3, CaptureParser.containsWord(firstName, in: lower) {
                score = 0.6
                // Recency: people you actually talk to outrank namesakes
                // last contacted a year ago.
                if let last = person.lastContactedAt {
                    let days = last.daysAgo
                    if days <= 14 { score += 0.1 } else if days <= 45 { score += 0.05 }
                }
            }
            if aiMentioned.contains(where: { $0.caseInsensitiveCompare(person.name) == .orderedSame || $0.caseInsensitiveCompare(person.firstName) == .orderedSame }) {
                score = max(score + 0.1, 0.5)
            }
            if score > 0 { scored.append((person, min(score, 0.98))) }
        }

        // 3. First-name collisions must never be guessed: if two or more
        //    people matched on the same first name with no stronger signal,
        //    demote all of them to candidates.
        var byFirstName: [String: Int] = [:]
        for entry in scored where entry.score < 0.9 {
            byFirstName[entry.person.firstName.lowercased(), default: 0] += 1
        }
        var candidates: [Candidate] = []
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            let ambiguous = entry.score < 0.9 && (byFirstName[entry.person.firstName.lowercased()] ?? 0) > 1
            if entry.score >= autoSelectThreshold, !ambiguous {
                resolution.matchedIDs.append(entry.person.id)
                resolution.confidence = resolution.confidence == 0
                    ? entry.score
                    : min(resolution.confidence, entry.score)
            } else if entry.score >= candidateThreshold {
                candidates.append(Candidate(personID: entry.person.id, score: entry.score))
            }
        }

        // 4. Nothing at all? Offer the most recently contacted people as
        //    one-tap chips so Needs Context is a single tap, not a search.
        if resolution.matchedIDs.isEmpty && candidates.isEmpty {
            let recent = active
                .filter { $0.lastContactedAt != nil }
                .sorted { ($0.lastContactedAt ?? .distantPast) > ($1.lastContactedAt ?? .distantPast) }
                .prefix(3)
            candidates = recent.map { Candidate(personID: $0.id, score: 0.2) }
        }

        resolution.candidates = candidates
        if resolution.confidence == 0 && !resolution.matchedIDs.isEmpty {
            resolution.confidence = 1.0
        }
        return resolution
    }
}
