import UIKit

/// Grounds a Fit Checker request in whatever's already typed into the Add
/// Event flow, and runs it through the configured AI provider. Unlike gift
/// ideas or the person summary, there's no deterministic offline fallback:
/// rating a photo needs a vision-capable model, so this only ever calls
/// BazaarLink and surfaces a clear notice otherwise. Nothing here is ever
/// written to a `Person` or `Interaction`; this is event-prep assistance
/// only and must never influence closeness, cadence, or relationship scores.
enum FitCheckEngine {
    /// A snapshot of the event form's current fields: built from live
    /// `@State`, not a saved `Event`, so it works while creating a brand-new
    /// event just as well as while editing an existing one.
    struct EventContext {
        var title: String
        var date: Date
        var location: String
        var purpose: String
        var notes: String
        var attendees: [Person]
    }

    static func contextText(for ctx: EventContext) -> String {
        var lines: [String] = []
        lines.append("Event: \(ctx.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled event" : ctx.title)")
        lines.append("When: \(ctx.date.formatted(date: .complete, time: .shortened))")
        if !ctx.location.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Location: \(ctx.location)")
        }
        if !ctx.purpose.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Purpose / description: \(ctx.purpose)")
        }
        if !ctx.notes.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Notes: \(ctx.notes)")
        }
        if !ctx.attendees.isEmpty {
            let people = ctx.attendees.map { person -> String in
                var descriptor = person.category.label
                if !person.relationshipToMe.isEmpty { descriptor += ", \(person.relationshipToMe)" }
                return "\(person.displayName) (\(descriptor))"
            }
            lines.append("Attendees: \(people.joined(separator: "; "))")
        } else {
            lines.append("Attendees: not specified yet")
        }
        return lines.joined(separator: "\n")
    }

    struct Outcome {
        let result: FitCheckResult?
        /// A clean, user-facing explanation whenever `result` is `nil`.
        let notice: String?
    }

    static func check(image: UIImage, context: EventContext) async -> Outcome {
        guard AIProvider.currentCase == .bazaarLink else {
            return Outcome(result: nil, notice: "Fit Checker needs a vision-capable AI. Switch AI Provider to BazaarLink in Settings.")
        }
        guard KeychainService.hasBazaarLinkAPIKey() else {
            let notice = AIServiceError.missingBazaarLinkAPIKey.errorDescription
            return Outcome(result: nil, notice: notice)
        }
        do {
            // No extra timeout wrap needed: BazaarLinkAIService's own
            // `send()` already races the network call against its deadline.
            let result = try await BazaarLinkAIService().checkFit(image: image, eventContext: contextText(for: context))
            return Outcome(result: result, notice: nil)
        } catch {
            let mapped = AIServiceError.from(error)
            mapped.logForDeveloper(context: "fit check")
            return Outcome(result: nil, notice: mapped.errorDescription)
        }
    }
}
