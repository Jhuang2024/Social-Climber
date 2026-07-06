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
/// they do — nothing here is random or hidden.
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

    static func compute(for person: Person, now: Date = .now) -> RelationshipScore {
        var factors: [ScoreFactor] = []
        let base = 50
        factors.append(ScoreFactor(label: "Baseline", points: base))

        let cadence = Double(RelationshipHealth.expectedCadenceDays(for: person))
        let interactions = person.interactions.sorted { $0.date > $1.date }

        // 1. Recency vs. the expected check-in cadence.
        if let days = RelationshipHealth.daysSinceContact(for: person) {
            let ratio = Double(days) / max(cadence, 1)
            switch ratio {
            case ..<0.5:
                factors.append(ScoreFactor(label: "Contacted recently", points: 18))
            case ..<1.0:
                factors.append(ScoreFactor(label: "In touch within your cadence", points: 10))
            case ..<2.0:
                factors.append(ScoreFactor(label: "No contact in \(days) days", points: -8))
            case ..<4.0:
                factors.append(ScoreFactor(label: "Overdue — \(days) days since contact", points: -16))
            default:
                factors.append(ScoreFactor(label: "Gone quiet — \(days) days since contact", points: -24))
            }
        } else {
            factors.append(ScoreFactor(label: "No interactions logged yet", points: -12))
        }

        // 2. Quality of the most recent interaction (within ~6 weeks).
        if let recent = interactions.first, recent.date.daysAgo <= 45 {
            switch recent.sentiment {
            case .great:
                factors.append(ScoreFactor(label: "Recent great interaction", points: 12))
            case .good:
                factors.append(ScoreFactor(label: "Recent positive interaction", points: 7))
            case .neutral:
                factors.append(ScoreFactor(label: "Recent interaction", points: 2))
            case .bad:
                factors.append(ScoreFactor(label: "Recent interaction went badly", points: -8))
            }
        }

        // 3. Consistency — how many interactions in the last 90 days.
        let recentCount = interactions.filter { $0.date.daysAgo <= 90 }.count
        switch recentCount {
        case 6...:
            factors.append(ScoreFactor(label: "Very consistent contact", points: 10))
        case 3...5:
            factors.append(ScoreFactor(label: "Consistent contact", points: 5))
        default:
            break
        }

        // 4. Follow-through — completed follow-up reminders reward the loop.
        let completedFollowUps = person.reminders.filter {
            $0.completed && $0.type == .followUp && $0.dueDate.daysAgo <= 90
        }.count
        if completedFollowUps > 0 {
            let pts = min(completedFollowUps * 4, 12)
            factors.append(ScoreFactor(label: "Completed \(completedFollowUps) follow-up\(completedFollowUps == 1 ? "" : "s")", points: pts))
        }

        // 5. Overdue reminders drag the score down.
        let overdue = person.reminders.filter { $0.isOverdue }.count
        if overdue > 0 {
            let pts = -min(overdue * 5, 15)
            factors.append(ScoreFactor(label: "\(overdue) overdue reminder\(overdue == 1 ? "" : "s")", points: pts))
        }

        // 6. Open follow-up loops flagged on interactions but not yet closed.
        let openLoops = interactions.filter { $0.followUpNeeded }.count
        if openLoops > 0 {
            let pts = -min(openLoops * 3, 9)
            factors.append(ScoreFactor(label: "\(openLoops) open follow-up loop\(openLoops == 1 ? "" : "s")", points: pts))
        }

        // 7. High-priority decay — priority people are held to a stricter bar.
        let status = person.status
        if person.priority >= 4 && (status == .goingQuiet || status == .dormant) {
            factors.append(ScoreFactor(label: "High-priority contact going cold", points: -8))
        }

        let total = max(0, min(100, factors.reduce(0) { $0 + $1.points }))
        return RelationshipScore(total: total, factors: factors)
    }
}
