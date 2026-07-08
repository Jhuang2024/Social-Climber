import Foundation

/// Single source of truth for how an interaction's quality/sentiment affects
/// a person's closeness. Used at creation, edit, and deletion time so every
/// call site nudges the score by the same amount and score changes always
/// reverse cleanly.
enum ClosenessScoring {
    /// Poorly-rated interactions cost points, neutral ones are a no-op, good
    /// ones earn a small bump, and great ones earn more, never the same flat
    /// nudge regardless of how the interaction actually went.
    static func delta(for sentiment: Sentiment) -> Int {
        switch sentiment {
        case .bad: -2
        case .neutral: 0
        case .good: 1
        case .great: 2
        }
    }

    /// Convenience overload for the raw 1–5 `quality` value stored on an
    /// `Interaction`.
    static func delta(forQuality quality: Int) -> Int {
        delta(for: Sentiment(quality: quality))
    }
}
