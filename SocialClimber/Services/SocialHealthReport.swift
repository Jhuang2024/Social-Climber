import Foundation

/// An aggregate, explainable 0–100 picture of your whole social life:
/// the same transparency contract as `RelationshipScore`, one level up:
/// every point comes from a labeled factor. Built from relationship scores
/// across all active people, interaction momentum, and (when Instagram
/// sync is connected) follower trends.
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
        followerEvents: [FollowerEvent],
        now: Date = .now
    ) -> SocialHealthReport {
        var factors: [ScoreFactor] = []
        let active = people.filter { !$0.isArchived && $0.createdAt <= now }
        let availableInteractions = interactions.filter { $0.date <= now }

        // 1. Average relationship score across active people: the core of
        //    social health is the state of the individual relationships.
        if active.isEmpty {
            factors.append(ScoreFactor(label: "No people tracked yet", points: 40))
        } else {
            let average = active.map { historicalRelationshipScore(for: $0, interactions: availableInteractions, now: now) }
                .reduce(0, +) / active.count
            // Scale the 0–100 average into a 0–50 contribution.
            factors.append(ScoreFactor(label: "Average relationship score (\(average))", points: average / 2))
        }

        // 2. Interaction momentum: last 30 days vs. the 30 before that.
        let recent = availableInteractions.filter { age(of: $0.date, at: now) <= 30 }.count
        let prior = availableInteractions.filter {
            let days = age(of: $0.date, at: now)
            return days > 30 && days <= 60
        }.count
        switch (recent, prior) {
        case (0, 0):
            break
        case let (r, p) where r > p:
            factors.append(ScoreFactor(label: "More active than last month (\(r) vs \(p))", points: min(6 + (r - p), 15)))
        case let (r, p) where r < p && p > 0:
            factors.append(ScoreFactor(label: "Quieter than last month (\(r) vs \(p))", points: max(-15, -(p - r) - 3)))
        default:
            factors.append(ScoreFactor(label: "Steady activity (\(recent) this month)", points: 5))
        }

        // 3. Breadth: how many distinct people you actually touched
        //    in the last 30 days.
        let touchedIDs = Set(availableInteractions.filter { age(of: $0.date, at: now) <= 30 }.flatMap { $0.people.map(\.persistentModelID) })
        switch touchedIDs.count {
        case 8...:
            factors.append(ScoreFactor(label: "In touch with \(touchedIDs.count) people this month", points: 12))
        case 4...7:
            factors.append(ScoreFactor(label: "In touch with \(touchedIDs.count) people this month", points: 7))
        case 1...3:
            factors.append(ScoreFactor(label: "Only \(touchedIDs.count) \(touchedIDs.count == 1 ? "person" : "people") this month", points: 2))
        default:
            break
        }

        // 4. Relationships going cold: high-priority ones count double.
        let cooling = active.filter { isCooling($0, interactions: availableInteractions, now: now) }
        let coolingHighPriority = cooling.filter { $0.priority >= 4 }.count
        if !cooling.isEmpty {
            let pts = -min(cooling.count * 2 + coolingHighPriority * 2, 14)
            factors.append(ScoreFactor(label: "\(cooling.count) relationship\(cooling.count == 1 ? "" : "s") going quiet", points: pts))
        }

        // 5. Instagram follower trend, last 30 days of recorded events.
        let recentEvents = followerEvents.filter { $0.date <= now && age(of: $0.date, at: now) <= 30 }
        let gained = recentEvents.filter { $0.kind == .gainedFollower }.count
        let lost = recentEvents.filter { $0.kind == .lostFollower }.count
        if gained > 0 || lost > 0 {
            let net = gained - lost
            if net > 0 {
                factors.append(ScoreFactor(label: "+\(net) net Instagram followers this month", points: min(net, 8)))
            } else if net < 0 {
                factors.append(ScoreFactor(label: "\(net) net Instagram followers this month", points: max(net, -8)))
            } else {
                factors.append(ScoreFactor(label: "Instagram followers held steady", points: 2))
            }
        }

        let total = max(0, min(100, factors.reduce(0) { $0 + $1.points }))
        return SocialHealthReport(total: total, factors: factors)
    }

    /// Rebuilds the relationship portion at a historical date from facts that
    /// existed by then. This keeps the chart honest instead of applying today's
    /// interactions to every point in the past.
    private static func historicalRelationshipScore(
        for person: Person,
        interactions: [Interaction],
        now: Date
    ) -> Int {
        let personID = person.persistentModelID
        let history = interactions
            .filter { interaction in interaction.people.contains { $0.persistentModelID == personID } }
            .sorted { $0.date > $1.date }
        let cadence = max(RelationshipHealth.expectedCadenceDays(for: person), 1)
        var points = 50

        if let latest = history.first {
            let days = age(of: latest.date, at: now)
            let ratio = Double(days) / Double(cadence)
            switch ratio {
            case ..<0.5: points += 18
            case ..<1.0: points += 10
            case ..<2.0: points -= 8
            case ..<4.0: points -= 16
            default: points -= 24
            }
            if days <= 45 {
                switch latest.sentiment {
                case .great: points += 12
                case .good: points += 7
                case .neutral: points += 2
                case .bad: points -= 8
                }
            }
        } else {
            points -= 12
        }

        switch history.filter({ age(of: $0.date, at: now) <= 90 }).count {
        case 6...: points += 10
        case 3...5: points += 5
        default: break
        }

        let completedFollowUps = person.reminders.filter {
            $0.completed && $0.type == .followUp && $0.dueDate <= now && age(of: $0.dueDate, at: now) <= 90
        }.count
        points += min(completedFollowUps * 4, 12)

        let overdue = person.reminders.filter { !$0.completed && $0.dueDate < now }.count
        points -= min(overdue * 5, 15)
        points -= min(history.filter(\.followUpNeeded).count * 3, 9)

        if person.priority >= 4, isCooling(person, interactions: interactions, now: now) {
            points -= 8
        }
        return max(0, min(100, points))
    }

    private static func isCooling(_ person: Person, interactions: [Interaction], now: Date) -> Bool {
        let personID = person.persistentModelID
        guard let latest = interactions
            .filter({ $0.people.contains { $0.persistentModelID == personID } })
            .map(\.date)
            .max()
        else { return true }
        return age(of: latest, at: now) >= RelationshipHealth.expectedCadenceDays(for: person)
    }

    private static func age(of date: Date, at now: Date) -> Int {
        max(0, Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: date),
            to: Calendar.current.startOfDay(for: now)
        ).day ?? 0)
    }
}
