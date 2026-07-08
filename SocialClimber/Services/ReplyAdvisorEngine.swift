import UIKit

/// Grounds a "How to Respond" request in everything Social Climber already
/// knows about a specific person, and runs it through the configured AI
/// provider. Like `FitCheckEngine`, there's no offline fallback — reading a
/// screenshot needs a vision-capable model — so this only calls OpenRouter
/// and otherwise surfaces a clear notice. The screenshots and the resulting
/// advice are never persisted here: this is a reply-drafting assist, not a
/// logged interaction, and must never touch closeness or interaction history.
enum ReplyAdvisorEngine {
    /// A plain-text digest of everything relevant to how the user should
    /// talk to this person — their profile, closeness, notes, strategy, and
    /// recent tone. Reuses `GiftIdeaEngine.context` for the shared facts
    /// (interests, notes, family, recent interactions, events) and layers on
    /// what a reply specifically needs: closeness, priority, and open loops.
    static func context(for person: Person) -> String {
        var lines: [String] = [GiftIdeaEngine.context(for: person)]

        lines.append("Closeness: \(person.closeness)/5")
        lines.append("Priority: \(person.priority)/5")
        lines.append("Relationship status: \(person.status.label)")

        let openReminders = person.openReminders.prefix(3).map(\.title)
        if !openReminders.isEmpty {
            lines.append("Open follow-ups: \(openReminders.joined(separator: "; "))")
        }

        if let topSuggestion = StrategyEngine.suggestions(for: person).first {
            lines.append("Current strategy read: \(topSuggestion.title) — \(topSuggestion.detail)")
        }

        return lines.joined(separator: "\n")
    }

    struct Outcome {
        let advice: ReplyAdvice?
        /// A clean, user-facing explanation whenever `advice` is `nil`.
        let notice: String?
    }

    static func analyze(images: [UIImage], person: Person) async -> Outcome {
        guard AIProvider.currentCase == .openRouter else {
            return Outcome(advice: nil, notice: "How to Respond needs a vision-capable AI — switch AI Provider to OpenRouter in Settings.")
        }
        guard KeychainService.hasOpenRouterAPIKey() else {
            let notice = AIServiceError.missingOpenRouterAPIKey.errorDescription
            return Outcome(advice: nil, notice: notice)
        }
        do {
            let personContext = context(for: person)
            let advice = try await OpenRouterAIService().analyzeReply(images: images, personContext: personContext)
            return Outcome(advice: advice, notice: nil)
        } catch {
            let mapped = AIServiceError.from(error)
            mapped.logForDeveloper(context: "reply advisor")
            return Outcome(advice: nil, notice: mapped.errorDescription)
        }
    }
}
