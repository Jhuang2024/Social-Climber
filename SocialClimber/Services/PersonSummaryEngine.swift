import Foundation

/// Builds the "AI Summary" shown on a person's profile: a short relationship
/// recap covering their most recent interaction, how many are logged, the
/// general tone lately, their current closeness, and a suggested next move.
///
/// Always computes the deterministic version first from data already on
/// disk, so the feature keeps working with zero network dependency. When
/// AI is enabled, it's asked to write a nicer version grounded in that same
/// deterministic digest; on any failure (missing/invalid key, timeout, rate
/// limit, network, bad response) this falls back to the deterministic text
/// instead of showing an error.
enum PersonSummaryEngine {
    struct Result {
        let text: String
        let isAIGenerated: Bool
        /// Set only when an AI attempt was made and failed: a clean,
        /// user-facing explanation, never a raw error.
        let notice: String?
    }

    static func summary(for person: Person) async -> Result {
        let deterministic = deterministicSummary(for: person)

        guard AIProvider.currentCase != .mock, KeychainService.hasAnyAIKey() else {
            return Result(text: deterministic, isAIGenerated: false, notice: nil)
        }

        do {
            let context = GiftIdeaEngine.context(for: person) + "\n\nDeterministic facts:\n" + deterministic
            // No extra timeout wrap needed here: BazaarLinkAIService already
            // races every request against its own deadline internally.
            let text = try await BazaarLinkAIService().summarizePerson(context: context)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Result(text: deterministic, isAIGenerated: false, notice: nil)
            }
            return Result(text: text, isAIGenerated: true, notice: nil)
        } catch {
            let mapped = AIServiceError.from(error)
            mapped.logForDeveloper(context: "person summary")
            return Result(text: deterministic, isAIGenerated: false, notice: mapped.errorDescription)
        }
    }

    /// Pure, offline, always-available summary built straight from what's
    /// already logged for this person.
    static func deterministicSummary(for person: Person) -> String {
        let interactions = person.sortedInteractions
        var lines: [String] = []

        if let mostRecent = interactions.first {
            let preview = mostRecent.preview.isEmpty ? mostRecent.type.label : mostRecent.preview
            lines.append("Most recent: \(mostRecent.date.relativeLabel), \(preview)")
        } else {
            lines.append("No interactions logged yet.")
        }

        lines.append("\(interactions.count) interaction\(interactions.count == 1 ? "" : "s") logged in total.")

        if !interactions.isEmpty {
            lines.append("Tone lately: \(toneTrend(for: interactions))")
        }

        lines.append("Closeness is currently \(person.closeness)/5.")
        lines.append("Suggested next step: \(suggestedNextAction(for: person, interactions: interactions))")

        return lines.joined(separator: " ")
    }

    /// Looks at up to the last 5 interactions and describes the mix of
    /// sentiment without pretending there's more precision than there is.
    private static func toneTrend(for interactions: [Interaction]) -> String {
        let recent = interactions.prefix(5)
        let good = recent.filter { $0.sentiment == .good || $0.sentiment == .great }.count
        let bad = recent.filter { $0.sentiment == .bad }.count
        let total = recent.count

        if bad == 0 && good == total {
            return "consistently positive"
        } else if bad > good {
            return "rockier than usual: a few recent interactions went poorly"
        } else if bad > 0 {
            return "mostly positive, with at least one rough interaction"
        } else {
            return "steady and neutral"
        }
    }

    /// Reuses `StrategyEngine`'s already-centralized, weighted rules (overdue
    /// follow-ups, silence vs. cadence, high-priority-no-plan, birthdays,
    /// etc.) instead of a second hand-rolled set of urgency checks that could
    /// drift from what the Strategy card already tells the user.
    private static func suggestedNextAction(for person: Person, interactions: [Interaction]) -> String {
        if interactions.isEmpty {
            return "Log your first interaction to start building a relationship history."
        }
        if let top = StrategyEngine.suggestions(for: person).first {
            return "\(top.title): \(top.detail)"
        }
        return "You're on track, no urgent action needed."
    }
}
