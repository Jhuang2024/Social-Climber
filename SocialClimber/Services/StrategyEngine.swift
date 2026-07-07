import SwiftUI

/// A single rule-based suggestion. Everything here is derived locally from the
/// person's own data — no AI, no network.
struct Suggestion: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let title: String
    let detail: String
    /// Higher = more urgent. Used for sorting.
    let weight: Int
    let person: Person?

    init(icon: String, color: Color, title: String, detail: String, weight: Int, person: Person? = nil) {
        self.icon = icon
        self.color = color
        self.title = title
        self.detail = detail
        self.weight = weight
        self.person = person
    }
}

/// Buckets of people/actions surfaced on the global Strategy screen.
struct GlobalStrategy {
    var reconnect: [Person] = []
    var highPriorityCold: [Person] = []
    var overdueFollowUps: [Person] = []
    var recentPositive: [Person] = []
    var nextMoves: [Suggestion] = []

    var isEmpty: Bool {
        reconnect.isEmpty && highPriorityCold.isEmpty && overdueFollowUps.isEmpty
            && recentPositive.isEmpty && nextMoves.isEmpty
    }
}

enum StrategyEngine {

    // MARK: Per-contact

    static func suggestions(for person: Person, now: Date = .now) -> [Suggestion] {
        // No logged interactions means no basis for a strategy — don't fabricate
        // placeholder advice for a contact we know nothing about yet.
        guard !person.isArchived, !person.interactions.isEmpty else { return [] }
        var out: [Suggestion] = []

        let cadence = RelationshipHealth.expectedCadenceDays(for: person)
        let days = RelationshipHealth.daysSinceContact(for: person)
        let interactions = person.sortedInteractions
        let recent = interactions.first
        let openReminders = person.openReminders
        let overdue = person.reminders.filter(\.isOverdue)
        let score = RelationshipScore.compute(for: person, now: now)

        // Overdue follow-up (most actionable).
        if let firstOverdue = overdue.first {
            out.append(Suggestion(
                icon: "exclamationmark.arrow.circlepath",
                color: .red,
                title: "You have an overdue follow-up",
                detail: "“\(firstOverdue.title)” was due \(firstOverdue.dueDate.relativeLabel).",
                weight: 100,
                person: person
            ))
        }

        // Long silence relative to cadence.
        if let days, days > cadence {
            out.append(Suggestion(
                icon: "clock.badge.exclamationmark",
                color: .orange,
                title: "It's been \(days) days",
                detail: "You usually reach out every ~\(cadence) days. Time for a check-in.",
                weight: 80 + min(days, 40),
                person: person
            ))
        }

        // Score decaying due to inactivity.
        if (score.band == .cooling || score.band == .cold),
           let days, days > cadence {
            out.append(Suggestion(
                icon: "chart.line.downtrend.xyaxis",
                color: score.band.color,
                title: "Score is decaying",
                detail: "Their relationship score (\(score.total)) is slipping from inactivity.",
                weight: 70,
                person: person
            ))
        }

        // High-priority contact with no upcoming reminder.
        if person.priority >= 4 && openReminders.isEmpty {
            out.append(Suggestion(
                icon: "star.circle",
                color: .purple,
                title: "High-priority, no plan",
                detail: "This is a priority contact with nothing scheduled. Set a reminder.",
                weight: 65,
                person: person
            ))
        }

        // Logged a favor — close the loop.
        if let favor = interactions.first(where: { $0.type == .favor && $0.date.daysAgo <= 30 }) {
            out.append(Suggestion(
                icon: "hands.sparkles",
                color: .teal,
                title: "Close the favor loop",
                detail: "You logged a favor on \(favor.date.shortFormat). Consider following up.",
                weight: 55,
                person: person
            ))
        }

        // Recent positive → keep momentum.
        if let recent, recent.date.daysAgo <= 14, recent.sentiment == .good || recent.sentiment == .great {
            let warm = person.status == .good
            out.append(Suggestion(
                icon: "flame",
                color: .pink,
                title: warm ? "Keep the momentum" : "Good time for a light follow-up",
                detail: "Your last interaction was \(recent.sentiment.label.lowercased()). A casual message keeps it warm.",
                weight: 45,
                person: person
            ))
        }

        // Open follow-up loops flagged on interactions.
        if let loop = interactions.first(where: { $0.followUpNeeded }), overdue.isEmpty {
            out.append(Suggestion(
                icon: "arrow.uturn.right.circle",
                color: .orange,
                title: "Open follow-up",
                detail: loop.nextMove.isEmpty ? "You marked a follow-up as needed." : "Next move: \(loop.nextMove)",
                weight: 50,
                person: person
            ))
        }

        // Upcoming birthday.
        if let bday = person.nextBirthday, bday.daysFromNow <= 14 {
            out.append(Suggestion(
                icon: "birthday.cake",
                color: .pink,
                title: "Birthday coming up",
                detail: "\(person.firstName)'s birthday is \(bday.formatted(.dateTime.month(.wide).day())).",
                weight: 75,
                person: person
            ))
        }

        return out.sorted { $0.weight > $1.weight }
    }

    // MARK: Global

    static func global(people: [Person], now: Date = .now) -> GlobalStrategy {
        // Contacts with no logged interactions have no basis for a strategy —
        // exclude them from every bucket instead of surfacing placeholder rows.
        let active = people.filter { !$0.isArchived && !$0.interactions.isEmpty }
        var g = GlobalStrategy()

        g.reconnect = active
            .filter { $0.status == .goingQuiet || $0.status == .dormant }
            .sorted { RelationshipScore.compute(for: $0).total < RelationshipScore.compute(for: $1).total }

        g.highPriorityCold = active
            .filter { $0.priority >= 4 && ($0.status == .goingQuiet || $0.status == .dormant || $0.status == .checkInSoon) }
            .sorted { $0.priority > $1.priority }

        g.overdueFollowUps = active
            .filter { $0.reminders.contains(where: \.isOverdue) }
            .sorted { ($0.reminders.filter(\.isOverdue).count) > ($1.reminders.filter(\.isOverdue).count) }

        g.recentPositive = active
            .filter { person in
                guard let recent = person.sortedInteractions.first else { return false }
                return recent.date.daysAgo <= 14 && (recent.sentiment == .good || recent.sentiment == .great)
            }
            .sorted { ($0.sortedInteractions.first?.date ?? .distantPast) > ($1.sortedInteractions.first?.date ?? .distantPast) }

        // Top suggested move per person, highest-urgency first.
        g.nextMoves = active
            .compactMap { suggestions(for: $0).first }
            .sorted { $0.weight > $1.weight }

        return g
    }
}
