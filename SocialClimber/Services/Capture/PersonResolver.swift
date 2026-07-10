import Foundation
import SwiftData

/// Resolves which known people one capture is about, returning ranked
/// candidates with confidence rather than a single optional guess.
///
/// Signals combined, strongest first: trusted context supplied by the entry
/// point (a profile, an event, an assignment) → exact full-name/nickname
/// matches → contact-method values → AI-mentioned names → unique first-name
/// matches, boosted by recency. Multiple plausible matches are never picked
/// silently: they come back as candidates and the capture goes to
/// Needs Context instead.
enum PersonResolver {

    struct Candidate: Identifiable {
        let person: Person
        let score: Double
        var id: PersistentIdentifier { person.persistentModelID }
    }

    struct Resolution {
        /// People confident enough to auto-attach.
        var matched: [Person] = []
        /// Ranked alternatives when nothing (or nothing more) was certain.
        var candidates: [Candidate] = []
        /// Confidence of the weakest auto-attached match (1.0 for trusted).
        var confidence: Double = 0
        /// True when the capture should wait for the user to say who it was.
        var needsContext: Bool { matched.isEmpty }
    }

    /// Thresholds: at or above `autoSelect` a unique match attaches itself;
    /// between `candidate` and `autoSelect` it becomes a one-tap chip.
    private static let autoSelectThreshold = 0.75
    private static let candidateThreshold = 0.35

    static func resolve(
        text: String,
        trustedNames: [String],
        aiMentioned: [String],
        people: [Person]
    ) -> Resolution {
        var resolution = Resolution()
        let active = people.filter { !$0.isArchived }
        let lower = " " + text.lowercased() + " "

        // 1. Trusted context wins outright, confidence 1.0.
        var matched: [Person] = []
        for name in trustedNames {
            if let person = active.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? active.first(where: { !$0.nickname.isEmpty && $0.nickname.caseInsensitiveCompare(name) == .orderedSame }) {
                if !matched.contains(where: { $0 === person }) { matched.append(person) }
            }
        }
        if !matched.isEmpty {
            resolution.matched = matched
            resolution.confidence = 1.0
            // Trusted context doesn't stop additional confident text matches
            // (e.g. "Met Daniel and Priya" from an event with both trusted
            // plus a third person named in text) — fall through and merge.
        }

        // 2. Score every person against the text.
        var scored: [(person: Person, score: Double)] = []
        for person in active {
            if matched.contains(where: { $0 === person }) { continue }
            var score = 0.0
            let fullName = person.name.lowercased()
            let nickname = person.nickname.lowercased()
            let firstName = person.firstName.lowercased()

            if !fullName.isEmpty, lower.contains(" \(fullName) ") || lower.contains(" \(fullName),") || lower.contains(" \(fullName).") || lower.contains(fullName) {
                score = max(score, 0.95)
            }
            if !nickname.isEmpty, containsWord(nickname, in: lower) {
                score = max(score, 0.9)
            }
            if person.contactMethods.contains(where: { !$0.value.isEmpty && lower.contains($0.value.lowercased()) }) {
                score = max(score, 0.9)
            }
            if score == 0, !firstName.isEmpty, firstName.count >= 3, containsWord(firstName, in: lower) {
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
                resolution.matched.append(entry.person)
                resolution.confidence = resolution.confidence == 0
                    ? entry.score
                    : min(resolution.confidence, entry.score)
            } else if entry.score >= candidateThreshold {
                candidates.append(Candidate(person: entry.person, score: entry.score))
            }
        }

        // 4. Nothing at all? Offer the most recently contacted people as
        //    one-tap chips so Needs Context is a single tap, not a search.
        if resolution.matched.isEmpty && candidates.isEmpty {
            let recent = active
                .filter { $0.lastContactedAt != nil }
                .sorted { ($0.lastContactedAt ?? .distantPast) > ($1.lastContactedAt ?? .distantPast) }
                .prefix(3)
            candidates = recent.map { Candidate(person: $0, score: 0.2) }
        }

        resolution.candidates = candidates
        if resolution.confidence == 0 && !resolution.matched.isEmpty {
            resolution.confidence = 1.0
        }
        return resolution
    }

    /// Word-boundary containment so "Sam" never matches "Samantha said hi".
    private static func containsWord(_ word: String, in paddedLower: String) -> Bool {
        guard !word.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
            return paddedLower.contains(" \(word) ")
        }
        let range = NSRange(paddedLower.startIndex..., in: paddedLower)
        return regex.firstMatch(in: paddedLower, range: range) != nil
    }
}
