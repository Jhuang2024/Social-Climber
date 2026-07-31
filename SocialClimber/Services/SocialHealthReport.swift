import Foundation
import SwiftData

/// An aggregate, explainable 0–100 picture of your whole social life:
/// the same transparency contract as `RelationshipScore`, one level up:
/// every point comes from a labeled factor. Built from relationship scores
/// across all active people plus interaction momentum and breadth.
///
/// Like the per-person score, this is computed in fractions off
/// `ScoreCurves` and rounded once, at the end. The previous version summed
/// integer buckets that were each flat across a wide band and capped on top
/// of that: "more active than last month" pinned at +15, breadth pinned at
/// +12, the relationship average integer-divided by two. So the total
/// could report the identical number for weeks on end while the underlying
/// relationships were visibly moving.
struct SocialHealthReport {
    let total: Int
    let factors: [ScoreFactor]

    /// Reuses the per-person score bands: the meaning ("strong/steady/
    /// cooling/cold") translates directly to the aggregate.
    var band: ScoreBand {
        switch total {
        case 75...: .strong
        case 55..<75: .steady
        case 35..<55: .cooling
        default: .cold
        }
    }

    var rankedFactors: [ScoreFactor] {
        factors.sorted { abs($0.points) > abs($1.points) }
    }

    static func compute(
        people: [Person],
        interactions: [Interaction],
        now: Date = .now
    ) -> SocialHealthReport {
        var raw: [RawScoreFactor] = []
        let active = people.filter { !$0.isArchived && $0.createdAt <= now }
        let availableInteractions = interactions.filter { $0.date <= now }

        // 1. Average relationship score across active people: the core of
        //    social health is the state of the individual relationships.
        //    Kept fractional; rounding each person's score before averaging
        //    threw away exactly the movement this chart is meant to show.
        if active.isEmpty {
            raw.append(RawScoreFactor("No people tracked yet", 40))
        } else {
            let average = active.reduce(0.0) { $0 + RelationshipScore.rawTotal(for: $1, now: now) }
                / Double(active.count)
            // Scale the 0–100 average into a 0–50 contribution.
            raw.append(RawScoreFactor("Average relationship score (\(Int(average.rounded())))", average / 2))
        }

        // 2. Momentum: whether your conversations are picking up or tailing
        //    off, measured as a fast time-decayed average against a slow
        //    one. Nothing here has a window to fall off, so the number
        //    drifts a little every day instead of only when an interaction
        //    crosses a 30-day edge.
        let fast = activityWeight(availableInteractions, from: now, halfLife: Self.fastHalfLife)
        let slow = activityWeight(availableInteractions, from: now, halfLife: Self.slowHalfLife)
        let recentCount = availableInteractions.filter { ScoreCurves.days(from: $0.date, to: now) <= 30 }.count
        let priorCount = availableInteractions.filter {
            let days = ScoreCurves.days(from: $0.date, to: now)
            return days > 30 && days <= 60
        }.count
        if fast > 0.05 || slow > 0.05 {
            // Fast vs. slow moving average, no windows to fall off: at a
            // constant rate the two settle at exactly `halfLifeRatio`, so
            // the log is 0 when nothing is changing, positive when you're
            // picking up, negative when you're tailing off. Doubling your
            // activity is worth what halving it costs, and it never
            // saturates into a flat cap.
            let ratio = (fast + 0.5) / (Self.halfLifeRatio * slow + 0.5)
            let trend = ScoreCurves.clamp(12 * log2(ratio), -15, 15)
            // A flat month is worth a small positive (consistency counts),
            // as a smooth bump around zero rather than a step, so holding
            // steady never jumps the score by 5 the moment the trend
            // crosses some threshold.
            let steadiness = 5 * exp(-pow(trend / 4, 2))
            let points = trend + steadiness
            let label: String = switch trend {
            case 1...: "More active than last month (\(recentCount) vs \(priorCount))"
            case ..<(-1): "Quieter than last month (\(recentCount) vs \(priorCount))"
            default: "Steady activity (\(recentCount) this month)"
            }
            raw.append(RawScoreFactor(label, points))
        }

        // 3. Breadth: how many distinct people you actually touched lately,
        //    each weighted by how recently.
        var breadthWeights: [PersistentIdentifier: Double] = [:]
        for interaction in availableInteractions {
            let weight = ScoreCurves.decayWeight(
                ageDays: ScoreCurves.days(from: interaction.date, to: now),
                halfLife: 21
            )
            guard weight > 0.02 else { continue }
            for person in interaction.people {
                breadthWeights[person.persistentModelID] = max(breadthWeights[person.persistentModelID] ?? 0, weight)
            }
        }
        let breadth = breadthWeights.values.reduce(0, +)
        if breadth > 0.05 {
            let reached = breadthWeights.count
            let points = ScoreCurves.saturating(breadth, ceiling: 13, scale: 5)
            raw.append(RawScoreFactor(
                reached >= 4
                    ? "In touch with \(reached) people this month"
                    : "Only \(reached) \(reached == 1 ? "person" : "people") this month",
                points
            ))
        }

        // 4. Relationships going cold, weighted by how far past their own
        //    cadence each one is; high-priority ones count double.
        var coolingSeverity = 0.0
        var coolingCount = 0
        for person in active {
            let overdueness = coolingOverdueness(person, now: now)
            guard overdueness > 0 else { continue }
            coolingCount += 1
            coolingSeverity += overdueness * (person.priority >= 4 ? 2 : 1)
        }
        if coolingCount > 0 {
            let points = -ScoreCurves.saturating(coolingSeverity, ceiling: 14, scale: 4)
            raw.append(RawScoreFactor(
                "\(coolingCount) relationship\(coolingCount == 1 ? "" : "s") going quiet",
                points
            ))
        }

        let resolved = ScoreRounding.resolve(raw)
        return SocialHealthReport(
            total: Int(ScoreCurves.clamp(Double(resolved.total), 0, 100)),
            factors: resolved.factors
        )
    }

    /// The two half-lives momentum compares. A hard "last 30 days vs. the
    /// 30 before" pair of windows would make an interaction jump between
    /// buckets on its 30th day; two overlapping decays have no edge to fall
    /// off, so the comparison drifts smoothly.
    private static let fastHalfLife = 14.0
    private static let slowHalfLife = 56.0
    /// What `fast / slow` settles at when activity is perfectly constant.
    private static var halfLifeRatio: Double { fastHalfLife / slowHalfLife }

    /// Time-decayed interaction volume: recent conversations count for close
    /// to 1, older ones fade toward 0 with the given half-life.
    private static func activityWeight(_ interactions: [Interaction], from now: Date, halfLife: Double) -> Double {
        interactions.reduce(0.0) { running, interaction in
            running + ScoreCurves.decayWeight(
                ageDays: ScoreCurves.days(from: interaction.date, to: now),
                halfLife: halfLife
            )
        }
    }

    /// How far past their expected cadence a person is, as a 0–1 ramp that
    /// starts the moment they're due rather than flipping on all at once.
    private static func coolingOverdueness(_ person: Person, now: Date) -> Double {
        let cadence = Double(RelationshipHealth.expectedCadenceDays(for: person, now: now))
        guard let latest = RelationshipHealth.lastContactDate(for: person, now: now) else { return 1 }
        let ratio = ScoreCurves.days(from: latest, to: now) / max(cadence, 1)
        guard ratio > 1 else { return 0 }
        return min(1, ratio - 1)
    }
}
