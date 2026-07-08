import Foundation

/// The small public context snapshot Locked In Fit publishes about the
/// user's readiness for the day. Social Climber only ever reads this file;
/// it never opens Locked In Fit's real database and never writes back to
/// this struct. Every field is optional because Locked In Fit's schema is
/// out of Social Climber's control: a missing, renamed, or added field
/// should degrade gracefully rather than fail the whole decode.
struct LockedInFitPublicContext: Codable, Equatable {
    var app: String
    var schemaVersion: Int
    var updatedAt: Date
    var today: Today

    /// A low/medium/high scale used loosely across Locked In Fit's fields
    /// below. Decoded field-by-field in `Today.init(from:)` with `try?`, so
    /// an unrecognized raw value comes back `nil` for that one field
    /// instead of throwing and losing the rest of the snapshot.
    enum Level: String, Codable {
        case low, medium, high
    }

    struct ImportantTask: Codable, Equatable {
        var id: String
        var title: String
        var priority: String?
    }

    struct Today: Codable, Equatable {
        var sleepScore: Int?
        var energyLevel: Level?
        var recoveryStatus: Level?
        var workoutPlanned: Bool?
        var workoutCompleted: Bool?
        var nutritionStatus: Level?
        var calorieStatus: Level?
        /// 0...1 (or 0...100; both are tolerated) fraction of today's health
        /// checklist that's been completed.
        var checklistCompletion: Double?
        var importantTasksDue: [ImportantTask]?

        private enum CodingKeys: String, CodingKey {
            case sleepScore, energyLevel, recoveryStatus, workoutPlanned, workoutCompleted
            case nutritionStatus, calorieStatus, checklistCompletion, importantTasksDue
        }

        init(
            sleepScore: Int? = nil,
            energyLevel: Level? = nil,
            recoveryStatus: Level? = nil,
            workoutPlanned: Bool? = nil,
            workoutCompleted: Bool? = nil,
            nutritionStatus: Level? = nil,
            calorieStatus: Level? = nil,
            checklistCompletion: Double? = nil,
            importantTasksDue: [ImportantTask]? = nil
        ) {
            self.sleepScore = sleepScore
            self.energyLevel = energyLevel
            self.recoveryStatus = recoveryStatus
            self.workoutPlanned = workoutPlanned
            self.workoutCompleted = workoutCompleted
            self.nutritionStatus = nutritionStatus
            self.calorieStatus = calorieStatus
            self.checklistCompletion = checklistCompletion
            self.importantTasksDue = importantTasksDue
        }

        /// Every field decoded independently with `try?` so one malformed
        /// value (an unexpected type, an unrecognized enum case) just comes
        /// back `nil` instead of failing every other field in the snapshot.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sleepScore = try? c.decodeIfPresent(Int.self, forKey: .sleepScore)
            energyLevel = try? c.decodeIfPresent(Level.self, forKey: .energyLevel)
            recoveryStatus = try? c.decodeIfPresent(Level.self, forKey: .recoveryStatus)
            workoutPlanned = try? c.decodeIfPresent(Bool.self, forKey: .workoutPlanned)
            workoutCompleted = try? c.decodeIfPresent(Bool.self, forKey: .workoutCompleted)
            nutritionStatus = try? c.decodeIfPresent(Level.self, forKey: .nutritionStatus)
            calorieStatus = try? c.decodeIfPresent(Level.self, forKey: .calorieStatus)
            checklistCompletion = try? c.decodeIfPresent(Double.self, forKey: .checklistCompletion)
            importantTasksDue = try? c.decodeIfPresent([ImportantTask].self, forKey: .importantTasksDue)
        }
    }

    /// Decodes a snapshot, returning `nil` for anything missing, stale in
    /// shape, or corrupted rather than throwing. Callers should treat `nil`
    /// exactly like "Locked In Fit isn't installed."
    static func decode(from data: Data) -> LockedInFitPublicContext? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .flexibleISO8601
        return try? decoder.decode(LockedInFitPublicContext.self, from: data)
    }
}

extension LockedInFitPublicContext.Today {
    private var hasLowEnergyOrRecovery: Bool {
        energyLevel == .low || recoveryStatus == .low
    }

    private var hasPoorSleep: Bool {
        guard let sleepScore else { return false }
        return sleepScore < 50
    }

    /// Three or more health/self-improvement tasks due today counts as a
    /// heavy checklist day, per the same threshold Social Climber uses
    /// elsewhere for "a lot going on."
    private var hasHeavyChecklist: Bool {
        (importantTasksDue?.count ?? 0) >= 3
    }

    /// Whether today's readiness is low enough that Social Climber should
    /// quiet down: fewer casual check-ins, only high-value social actions
    /// surfaced.
    var isLowReadiness: Bool {
        hasLowEnergyOrRecovery || hasPoorSleep || hasHeavyChecklist
    }

    /// A short, practical, non-cringe line for the dashboard's readiness
    /// card explaining *why* today looks the way it does.
    var readinessSummary: String {
        if hasLowEnergyOrRecovery || hasPoorSleep {
            return "Low recovery today. Prioritizing only important social tasks."
        }
        if hasHeavyChecklist {
            return "Busy health checklist today. Showing fewer casual reminders."
        }
        let energy = energyLevel?.rawValue ?? "normal"
        return "Energy: \(energy). Showing normal social reminders."
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// Tries ISO 8601 with fractional seconds first, then without, so a
    /// snapshot from either formatter convention decodes instead of
    /// silently losing the whole file over a timestamp format mismatch.
    static var flexibleISO8601: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date string, got \(string)"
            )
        }
    }
}
