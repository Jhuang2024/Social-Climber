import Foundation

/// Generates AI gift suggestions for a person, grounded only in facts the
/// app already has on file. Contacts with no logged interactions have no
/// basis for a suggestion and are never passed in here (see StrategyEngine's
/// same rule for suggestions/priorities).
enum GiftIdeaEngine {
    /// A plain-text digest of everything Social Climber knows about a
    /// person, the only material handed to the AI as grounding context.
    static func context(for person: Person) -> String {
        var lines: [String] = []
        lines.append("Name: \(person.displayName)")
        if !person.relationshipToMe.isEmpty { lines.append("Relationship: \(person.relationshipToMe)") }
        lines.append("Category: \(person.category.label)")
        if !person.interests.isEmpty { lines.append("Interests: \(person.interests.joined(separator: ", "))") }
        if !person.dislikes.isEmpty { lines.append("Dislikes: \(person.dislikes.joined(separator: ", "))") }
        if !person.personalityNotes.isEmpty { lines.append("Personality notes: \(person.personalityNotes)") }
        if !person.notes.isEmpty { lines.append("General notes: \(person.notes)") }
        if !person.tags.isEmpty { lines.append("Tags: \(person.tags.joined(separator: ", "))") }
        if !person.familyMembers.isEmpty { lines.append("Family: \(person.familyMembers.joined(separator: ", "))") }
        if !person.schoolOrWork.isEmpty { lines.append("School / Work: \(person.schoolOrWork)") }
        if !person.location.isEmpty { lines.append("Location: \(person.location)") }

        if let birthday = person.nextBirthday {
            lines.append("Upcoming birthday: \(birthday.formatted(.dateTime.month(.wide).day()))")
        }
        let upcomingDates = person.importantDates.compactMap { date -> String? in
            guard let next = date.nextOccurrence else { return nil }
            return "\(date.title): \(next.formatted(.dateTime.month(.wide).day()))"
        }
        if !upcomingDates.isEmpty {
            lines.append("Upcoming important dates: \(upcomingDates.joined(separator: "; "))")
        }

        let recentInteractions = person.sortedInteractions.prefix(6).compactMap { interaction -> String? in
            var parts = [interaction.date.shortFormat]
            if !interaction.topics.isEmpty { parts.append("topics: \(interaction.topics.joined(separator: ", "))") }
            if !interaction.messageSummary.isEmpty {
                parts.append(interaction.messageSummary)
            } else if !interaction.note.isEmpty {
                parts.append(interaction.note)
            }
            return parts.count > 1 ? parts.joined(separator: "; ") : nil
        }
        if !recentInteractions.isEmpty {
            lines.append("Recent interactions:\n" + recentInteractions.map { "- \($0)" }.joined(separator: "\n"))
        }

        let events = person.events.filter { !$0.isUpcoming }.map(\.name).filter { !$0.isEmpty }.prefix(5)
        if !events.isEmpty {
            lines.append("Past events attended: \(events.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    struct Outcome {
        let suggestions: [GiftSuggestion]
        /// True when `suggestions` came from the local heuristic fallback
        /// rather than the configured AI provider.
        let degraded: Bool
        /// A clean, user-facing explanation of why it degraded. `nil` when
        /// the request succeeded normally.
        let notice: String?
    }

    /// Tries the configured AI provider first; if it fails for any reason
    /// (missing/invalid key, rate limit, timeout, network, bad response),
    /// falls back to the deterministic local suggestions built from the
    /// person's own logged interests rather than surfacing a raw error,
    /// same shape as `AIExtractionCoordinator.extract`.
    static func suggestions(for person: Person) async -> Outcome {
        let existingTitles = person.giftIdeas.map(\.title)
        let personContext = context(for: person)
        do {
            let result = try await AIProvider.current.suggestGiftIdeas(
                personContext: personContext,
                existingGiftTitles: existingTitles
            )
            return Outcome(suggestions: result, degraded: false, notice: nil)
        } catch {
            let mapped = AIServiceError.from(error)
            mapped.logForDeveloper(context: "gift suggestions")
            let fallback = (try? await MockAIService().suggestGiftIdeas(
                personContext: personContext,
                existingGiftTitles: existingTitles
            )) ?? []
            return Outcome(suggestions: fallback, degraded: true, notice: mapped.errorDescription)
        }
    }
}
