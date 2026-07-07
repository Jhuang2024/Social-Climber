import Foundation

/// Wraps note/message extraction so every call site gets the same
/// reliability guarantees: a bounded timeout, and — if the configured AI
/// provider fails for any reason (missing/invalid key, rate limit, timeout,
/// network failure, malformed response) — a deterministic local fallback
/// instead of an empty result or a blocked save.
enum AIExtractionCoordinator {
    struct Outcome {
        let extraction: AIExtraction
        /// True when `extraction` came from the local heuristic fallback
        /// rather than the configured AI provider.
        let degraded: Bool
        /// A clean, user-facing explanation of why it degraded. `nil` when
        /// the request succeeded normally.
        let notice: String?
    }

    static func extract(from text: String, knownPeople: [String]) async -> Outcome {
        let provider = AIProvider.current
        do {
            let result = try await provider.extract(from: text, knownPeople: knownPeople)
            return Outcome(extraction: result, degraded: false, notice: nil)
        } catch {
            let mapped = AIServiceError.from(error)
            mapped.logForDeveloper(context: "note extraction")
            let fallback = (try? await MockAIService().extract(from: text, knownPeople: knownPeople))
                ?? AIExtraction(summary: text)
            return Outcome(extraction: fallback, degraded: true, notice: mapped.errorDescription)
        }
    }
}
