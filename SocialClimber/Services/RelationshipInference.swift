import Foundation

/// Works out how the user actually knows someone from what their
/// conversations show, instead of parking every automatically-created
/// contact on the generic "Acquaintance" default forever.
///
/// Two halves live here:
///
/// * `guesses(in:subjectNames:)` — the offline heuristic, used by
///   `MockAIService` and as the floor when a real provider returns nothing.
///   It only fires on wording that genuinely states a relationship, and it
///   would rather say nothing than guess.
/// * `apply(_:to:)` — the write policy, shared by every caller. A category
///   a human picked is never overwritten, and a weaker read never
///   supersedes a stronger earlier one.
enum RelationshipInference {

    /// The minimum confidence worth writing to a profile at all.
    static let applyThreshold = 0.5

    // MARK: Write policy

    enum Outcome {
        case unchanged
        case applied(category: PersonCategory?, descriptor: String?)
    }

    /// Writes an inferred relationship onto a person, subject to the rules
    /// above. Returns what (if anything) actually changed so the caller can
    /// record provenance for it.
    @discardableResult
    static func apply(_ guess: ExtractedRelationship, to person: Person) -> Outcome {
        guard guess.confidence >= applyThreshold else { return .unchanged }

        var appliedCategory: PersonCategory?
        if let category = PersonCategory(rawValue: guess.category),
           !person.categoryIsUserSet,
           guess.confidence >= person.inferredRelationshipConfidence,
           category != person.category {
            person.category = category
            appliedCategory = category
        }

        var appliedDescriptor: String?
        let descriptor = guess.descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !descriptor.isEmpty,
           !person.relationshipIsUserSet,
           guess.confidence >= person.inferredRelationshipConfidence,
           descriptor.caseInsensitiveCompare(person.relationshipToMe) != .orderedSame {
            person.relationshipToMe = descriptor
            appliedDescriptor = descriptor
        }

        guard appliedCategory != nil || appliedDescriptor != nil else { return .unchanged }
        person.inferredRelationshipConfidence = max(person.inferredRelationshipConfidence, guess.confidence)
        person.updatedAt = .now
        return .applied(category: appliedCategory, descriptor: appliedDescriptor)
    }

    // MARK: Offline heuristic

    /// Relationship words that state the tie outright, mapped to the
    /// category they imply. Order matters: longer, more specific phrases are
    /// checked first so "best friend" doesn't match as plain "friend".
    private static let explicitTerms: [(term: String, category: PersonCategory)] = [
        ("best friend", .closeFriend), ("bestie", .closeFriend), ("closest friend", .closeFriend),
        ("lab partner", .classmate), ("group partner", .classmate), ("classmate", .classmate),
        ("study partner", .classmate), ("teammate", .friend),
        ("roommate", .roommate), ("housemate", .roommate), ("flatmate", .roommate), ("suitemate", .roommate),
        ("co-worker", .professional), ("coworker", .professional), ("colleague", .professional),
        ("manager", .professional), ("supervisor", .professional), ("boss", .professional),
        ("client", .professional), ("recruiter", .professional), ("business partner", .professional),
        ("mentor", .mentor), ("advisor", .mentor), ("professor", .mentor), ("teacher", .mentor),
        ("coach", .mentor), ("tutor", .mentor),
        ("stepmom", .family), ("stepdad", .family), ("grandmother", .family), ("grandfather", .family),
        ("grandma", .family), ("grandpa", .family), ("mother", .family), ("father", .family),
        ("brother", .family), ("sister", .family), ("cousin", .family), ("aunt", .family),
        ("uncle", .family), ("nephew", .family), ("niece", .family), ("sibling", .family),
        ("wife", .family), ("husband", .family), ("mom", .family), ("dad", .family),
        ("girlfriend", .closeFriend), ("boyfriend", .closeFriend), ("partner", .closeFriend),
        ("acquaintance", .acquaintance), ("buddy", .friend), ("friend", .friend),
    ]

    /// Vocabulary that reveals a shared context without naming the tie.
    /// Much weaker, so it needs several distinct hits before it counts.
    private static let contextTerms: [(term: String, category: PersonCategory)] = [
        ("homework", .classmate), ("the test", .classmate), ("the exam", .classmate),
        ("midterm", .classmate), ("final exam", .classmate), ("our class", .classmate),
        ("in class", .classmate), ("the assignment", .classmate), ("lecture", .classmate),
        ("our teacher", .classmate), ("the syllabus", .classmate),
        ("our apartment", .roommate), ("the apartment", .roommate), ("our place", .roommate),
        ("the rent", .roommate), ("our kitchen", .roommate), ("the dishes", .roommate),
        ("standup", .professional), ("the office", .professional), ("our manager", .professional),
        ("the client", .professional), ("the deadline at work", .professional),
        ("our sprint", .professional), ("the deploy", .professional),
    ]

    /// Wording that makes a relationship word refer to somebody *else*
    /// ("my mom said…" in a chat with a friend describes the speaker's
    /// mother, not the person being talked to).
    private static let thirdPartyPrefixes = ["my ", "his ", "her ", "their ", "your "]

    /// Reads relationship signals out of one capture's text.
    ///
    /// `subjectNames` is who the capture is already known to be about; a
    /// guess is only emitted for those people, because "roommate" appearing
    /// somewhere in a conversation says nothing about a contact the sentence
    /// never referred to.
    static func guesses(in text: String, subjectNames: [String]) -> [ExtractedRelationship] {
        let subjects = subjectNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !subjects.isEmpty else { return [] }

        let lower = text.lowercased()
        var results: [ExtractedRelationship] = []

        for subject in subjects {
            let firstName = subject.components(separatedBy: " ").first ?? subject

            // Tier 1: a sentence that names this person and states the tie.
            if let hit = explicitHit(in: text, subject: subject, firstName: firstName) {
                results.append(ExtractedRelationship(
                    personName: subject,
                    category: hit.category.rawValue,
                    descriptor: hit.term.capitalizedFirst,
                    confidence: 0.85
                ))
                continue
            }

            // Tier 2: several independent shared-context signals across the
            // whole conversation, and only when they agree on one category.
            var hitsByCategory: [PersonCategory: Set<String>] = [:]
            for entry in contextTerms where lower.contains(entry.term) {
                hitsByCategory[entry.category, default: []].insert(entry.term)
            }
            let ranked = hitsByCategory.sorted { $0.value.count > $1.value.count }
            if let best = ranked.first, best.value.count >= 3,
               ranked.dropFirst().first.map({ $0.value.count < best.value.count }) ?? true {
                results.append(ExtractedRelationship(
                    personName: subject,
                    category: best.key.rawValue,
                    descriptor: "",
                    confidence: 0.55
                ))
            }
        }
        return results
    }

    /// The first relationship word stated about `subject` in a sentence that
    /// actually names them, skipping "my mom"-style third-party mentions.
    private static func explicitHit(
        in text: String,
        subject: String,
        firstName: String
    ) -> (term: String, category: PersonCategory)? {
        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            let lower = sentence.lowercased()
            guard lower.contains(subject.lowercased()) || lower.contains(firstName.lowercased()) else { continue }
            for entry in explicitTerms {
                guard let range = lower.range(of: entry.term) else { continue }
                // "<name> is my roommate" and "my roommate <name>" both mean
                // the person named; a possessive that points somewhere else
                // ("his sister", "your boss") does not.
                let prefix = String(lower[lower.startIndex..<range.lowerBound])
                let ownedByOther = thirdPartyPrefixes
                    .filter { $0 != "my " }
                    .contains { prefix.hasSuffix($0) }
                if ownedByOther { continue }
                return (entry.term, entry.category)
            }
        }
        return nil
    }
}
