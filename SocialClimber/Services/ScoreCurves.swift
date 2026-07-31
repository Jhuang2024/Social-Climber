import Foundation

/// The shared, **continuous** building blocks behind `RelationshipScore` and
/// `SocialHealthReport`.
///
/// Both scores used to be built from step functions ("less than half a
/// cadence → +18", "6 or more interactions → +10", "cap the momentum bonus
/// at 15"). Every one of those steps is flat across a wide band, and the
/// bands are wide compared to how fast real life moves, so a score could sit
/// on exactly the same integer for weeks while the underlying relationships
/// genuinely changed. Worse, the capped terms saturate: once you're past the
/// cap, more activity changes nothing at all.
///
/// Everything here is smooth instead: interpolated ramps rather than
/// buckets, exponentially time-decayed weights rather than raw counts inside
/// a hard window, and diminishing-returns curves rather than hard caps. A
/// day passing, or one new interaction landing, always moves the number.
enum ScoreCurves {

    /// Fractional (not calendar-truncated) days between a past date and
    /// `now`, floored at zero. Fractions matter: whole-day truncation is
    /// itself a step function.
    static func days(from date: Date, to now: Date) -> Double {
        max(0, now.timeIntervalSince(date) / 86_400)
    }

    /// Piecewise-linear interpolation through ascending `(x, y)` anchors,
    /// clamped flat outside the first and last anchor.
    static func interpolate(_ x: Double, through anchors: [(x: Double, y: Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where x <= upper.x {
            let span = upper.x - lower.x
            guard span > 0 else { return upper.y }
            return lower.y + (upper.y - lower.y) * ((x - lower.x) / span)
        }
        return last.y
    }

    /// How much a relationship's recency is worth, as a smooth ramp over
    /// "how many expected check-in cadences have elapsed". Same endpoints the
    /// old buckets used (+18 fresh, -24 gone quiet); the difference is that
    /// every day in between now has its own value.
    private static let recencyAnchors: [(x: Double, y: Double)] = [
        (0.0, 18), (0.5, 13), (1.0, 4), (2.0, -8), (4.0, -18), (6.0, -24),
    ]

    static func recencyPoints(daysSinceContact: Double, cadenceDays: Double) -> Double {
        interpolate(daysSinceContact / max(cadenceDays, 1), through: recencyAnchors)
    }

    /// Exponential decay weight for an event `ageDays` old: 1.0 today,
    /// 0.5 after one half-life, never quite zero. Used instead of "count
    /// everything inside a 30/90-day window", which changes only on the day
    /// something falls off the edge.
    static func decayWeight(ageDays: Double, halfLife: Double) -> Double {
        pow(0.5, max(0, ageDays) / max(halfLife, 1))
    }

    /// Diminishing returns: 0 at 0, rising smoothly toward `ceiling`,
    /// reaching ~63% of it at `scale`. Replaces hard caps, which stop
    /// responding entirely once passed.
    static func saturating(_ value: Double, ceiling: Double, scale: Double) -> Double {
        guard value > 0 else { return 0 }
        return ceiling * (1 - exp(-value / max(scale, 0.0001)))
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}

/// One fractional contribution to a score, before it's rounded for display.
struct RawScoreFactor {
    let label: String
    let points: Double

    init(_ label: String, _ points: Double) {
        self.label = label
        self.points = points
    }
}

/// Turns fractional contributions into the whole numbers the UI shows.
///
/// The scores are computed in fractions so they move day to day, but the
/// transparency contract is that the itemized factors add up to the score.
/// Rounding each factor independently breaks that (five factors rounding up
/// makes the list overshoot the total by 2). Largest-remainder apportionment
/// keeps both properties: every factor is a whole number, and they sum to
/// exactly the reported total.
enum ScoreRounding {
    static func resolve(_ raw: [RawScoreFactor]) -> (factors: [ScoreFactor], total: Int) {
        guard !raw.isEmpty else { return ([], 0) }
        let target = Int(raw.reduce(0.0) { $0 + $1.points }.rounded())
        var whole = raw.map { Int($0.points.rounded(.down)) }
        var shortfall = target - whole.reduce(0, +)

        // Hand the leftover points to whichever factors were cut hardest by
        // rounding down (largest fractional part first).
        let byRemainder = raw.enumerated()
            .map { (index: $0.offset, remainder: $0.element.points - $0.element.points.rounded(.down)) }
            .sorted { $0.remainder > $1.remainder }
        var cursor = 0
        while shortfall > 0 && !byRemainder.isEmpty {
            whole[byRemainder[cursor % byRemainder.count].index] += 1
            shortfall -= 1
            cursor += 1
        }
        while shortfall < 0 && !byRemainder.isEmpty {
            whole[byRemainder[byRemainder.count - 1 - (cursor % byRemainder.count)].index] -= 1
            shortfall += 1
            cursor += 1
        }

        let factors = raw.enumerated().map { ScoreFactor(label: $0.element.label, points: whole[$0.offset]) }
        return (factors, target)
    }
}
