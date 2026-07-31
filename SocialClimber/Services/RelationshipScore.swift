import SwiftUI

/// A single, explainable contribution to a person's relationship score.
struct ScoreFactor: Identifiable {
    let id = UUID()
    let label: String
    let points: Int

    var isPositive: Bool { points >= 0 }
    var signedString: String { points >= 0 ? "+\(points)" : "\(points)" }
}

enum ScoreBand: String {
    case strong, steady, cooling, cold

    var label: String {
        switch self {
        case .strong: "Strong"
        case .steady: "Steady"
        case .cooling: "Cooling"
        case .cold: "Cold"
        }
    }

    var color: Color {
        switch self {
        case .strong: .green
        case .steady: .teal
        case .cooling: .orange
        case .cold: .red
        }
    }

    var icon: String {
        switch self {
        case .strong: "flame.fill"
        case .steady: "checkmark.seal.fill"
        case .cooling: "thermometer.medium"
        case .cold: "snowflake"
        }
    }
}

/// A fully transparent 0–100 relationship score. Every point is attributable
/// to a labeled factor so the user can always see *why* a contact sits where
/// they do: nothing here is random or hidden.
///
/// Computed in fractions off `ScoreCurves` (smooth ramps and time-decayed
/// weights) and rounded once at the end, so the number responds to a day
/// passing or a message landing instead of sitting on the same integer until
/// some bucket boundary is crossed.
struct RelationshipScore {
    let total: Int
    let factors: [ScoreFactor]

    var band: ScoreBand {
        switch total {
        case 75...: .strong
        case 55..<75: .steady
        case 35..<55: .cooling
        default: .cold
        }
    }

    /// Factors sorted most-impactful first (largest magnitude), keeping the
    /// signed order stable for ties.
    var rankedFactors: [ScoreFactor] {
        factors.sorted { abs($0.points) > abs($1.points) }
    }

    /// The unrounded score, used by `SocialHealthReport` so the aggregate
    /// average doesn't quantize every person to a whole number before
    /// averaging them (which was enough on its own to freeze the average).
    static func rawTotal(for person: Person, now: Date = .now) -> Double {
        ScoreCurves.clamp(rawFactors(for: person, now: now).reduce(0) { $0 + $1.points }, 0, 100)
    }

    static func compute(for person: Person, now: Date = .now) -> RelationshipScore {
        let resolved = ScoreRounding.resolve(rawFactors(for: person, now: now))
        return RelationshipScore(
            total: Int(ScoreCurves.clamp(Double(resolved.total), 0, 100)),
            factors: resolved.factors
        )
    }

    // MARK: Factors

    private static func rawFactors(for person: Person, now: Date = .now) -> [RawScoreFactor] {
        var factors: [RawScoreFactor] = [RawScoreFactor("Baseline", 50)]

        let cadence = Double(RelationshipHealth.expectedCadenceDays(for: person, now: now))
        let interactions = person.interactions
            .filter { $0.date <= now }
            .sorted { $0.date > $1.date }
        let lastContact = RelationshipHealth.lastContactDate(for: person, now: now)

        // 1. Recency vs. the expected check-in cadence, as a smooth ramp.
        if let latest = lastContact {
            let days = ScoreCurves.days(from: latest, to: now)
            let points = ScoreCurves.recencyPoints(daysSinceContact: days, cadenceDays: cadence)
            let wholeDays = Int(days)
            let label: String = switch points {
            case 12...: "Contacted recently"
            case 0..<12: "In touch within your cadence"
            case -12..<0: "No contact in \(wholeDays) days"
            default: "Gone quiet: \(wholeDays) days since contact"
            }
            factors.append(RawScoreFactor(label, points))
        } else {
            factors.append(RawScoreFactor("No interactions logged yet", -12))
        }

        // 2. Tone lately: every interaction of the last while, weighted by how
        //    recent it is, rather than only the single newest one. One good
        //    conversation stops being worth the same +7 for six weeks and
        //    then nothing.
        let sentimentHalfLife = 21.0
        var sentimentWeight = 0.0
        var sentimentValue = 0.0
        for interaction in interactions {
            let weight = ScoreCurves.decayWeight(
                ageDays: ScoreCurves.days(from: interaction.date, to: now),
                halfLife: sentimentHalfLife
            )
            guard weight > 0.02 else { break }
            sentimentWeight += weight
            sentimentValue += weight * sentimentPoints(interaction.sentiment)
        }
        if sentimentWeight > 0 {
            // Fades in with the total weight, so a single stale interaction
            // doesn't carry the same authority as a run of recent ones.
            let confidence = ScoreCurves.saturating(sentimentWeight, ceiling: 1, scale: 1.2)
            let points = (sentimentValue / sentimentWeight) * confidence
            let label: String = switch points {
            case 6...: "Recent interactions went great"
            case 1.5..<6: "Recent interactions went well"
            case -1.5..<1.5: "Recent contact, neutral tone"
            default: "Recent interactions went badly"
            }
            factors.append(RawScoreFactor(label, points))
        }

        // 3. Consistency: time-decayed volume, so old interactions fade out
        //    gradually instead of dropping off a 90-day cliff.
        let consistencyWeight = interactions.reduce(0.0) { running, interaction in
            running + ScoreCurves.decayWeight(
                ageDays: ScoreCurves.days(from: interaction.date, to: now),
                halfLife: 45
            )
        }
        if consistencyWeight > 0.05 {
            let points = ScoreCurves.saturating(consistencyWeight, ceiling: 12, scale: 3)
            factors.append(RawScoreFactor(points >= 7 ? "Very consistent contact" : "Consistent contact", points))
        }

        // 4. Follow-through: completed follow-up reminders reward the loop,
        //    fading as they age.
        let followThrough = person.reminders
            .filter { $0.completed && $0.type == .followUp && $0.dueDate <= now }
            .reduce(0.0) { running, reminder in
                running + ScoreCurves.decayWeight(
                    ageDays: ScoreCurves.days(from: reminder.dueDate, to: now),
                    halfLife: 60
                )
            }
        if followThrough > 0.05 {
            let points = ScoreCurves.saturating(followThrough, ceiling: 12, scale: 2.5)
            factors.append(RawScoreFactor("Followed through on what you said you'd do", points))
        }

        // 5. Overdue reminders drag the score down, and keep dragging harder
        //    the longer they sit.
        let overdue = person.reminders.filter { !$0.completed && $0.dueDate < now }
        if !overdue.isEmpty {
            let severity = overdue.reduce(0.0) { running, reminder in
                running + min(1, ScoreCurves.days(from: reminder.dueDate, to: now) / 7 + 0.2)
            }
            let points = -ScoreCurves.saturating(severity, ceiling: 15, scale: 2.5)
            factors.append(RawScoreFactor("\(overdue.count) overdue reminder\(overdue.count == 1 ? "" : "s")", points))
        }

        // 6. Open follow-up loops flagged on interactions but not yet closed.
        let openLoops = interactions.filter(\.followUpNeeded).count
        if openLoops > 0 {
            let points = -ScoreCurves.saturating(Double(openLoops), ceiling: 9, scale: 2)
            factors.append(RawScoreFactor("\(openLoops) open follow-up loop\(openLoops == 1 ? "" : "s")", points))
        }

        // 7. High-priority decay: priority people are held to a stricter
        //    bar. Derived from the cadence already computed above rather
        //    than calling `RelationshipHealth.status`, which would redo the
        //    whole cadence/rhythm calculation — expensive here, since the
        //    trend chart replays this for every person at ~60 past dates.
        if person.priority >= 4 {
            let overdueRatio = lastContact
                .map { ScoreCurves.days(from: $0, to: now) / max(cadence, 1) }
                ?? 0
            let openFollowUps = person.reminders.filter { !$0.completed && $0.type == .followUp }.count + openLoops
            let adjusted = overdueRatio + Double(min(openFollowUps, 3)) * 0.15
            // 1.75 is the same threshold `RelationshipHealth.status` uses to
            // call a relationship "going quiet".
            if adjusted >= 1.75 {
                factors.append(RawScoreFactor("High-priority contact going cold", -8))
            }
        }

        return factors
    }

    private static func sentimentPoints(_ sentiment: Sentiment) -> Double {
        switch sentiment {
        case .great: 12
        case .good: 7
        case .neutral: 2
        case .bad: -8
        }
    }
}
