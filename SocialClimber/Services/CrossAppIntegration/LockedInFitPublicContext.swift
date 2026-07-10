import Foundation

/// The small public context snapshot LockedInFit publishes about the user's
/// readiness for the day. Social Climber only ever reads this file: it
/// never opens LockedInFit's real database and never writes back to this
/// struct. Every field decodes defensively, since LockedInFit's schema
/// evolving over time (a renamed field, a new one) should degrade
/// gracefully rather than fail the whole decode.
struct LockedInFitPublicContext: Codable, Equatable {
    var app: String
    var schemaVersion: Int
    var updatedAt: Date
    var today: Today

    struct ImportantHealthTask: Codable, Equatable {
        var id: String
        var title: String
        var category: String?
        var priority: String?
    }

    struct Today: Codable, Equatable {
        var sleepScore: Int?
        var energyLevel: CrossAppLevel
        var recoveryStatus: CrossAppLevel
        var workoutPlannedToday: Bool?
        var workoutCompletedToday: Bool?
        var nutritionStatus: CrossAppLevel
        var calorieStatus: CrossAppLevel
        /// 0...1 (or 0...100; both are tolerated) fraction of today's health
        /// checklist that's been completed.
        var dailyChecklistCompletion: Double?
        var importantHealthTasksDue: [ImportantHealthTask]?

        private enum CodingKeys: String, CodingKey {
            case sleepScore, energyLevel, recoveryStatus, workoutPlannedToday, workoutCompletedToday
            case nutritionStatus, calorieStatus, dailyChecklistCompletion, importantHealthTasksDue
        }

        init(
            sleepScore: Int? = nil,
            energyLevel: CrossAppLevel = .unknown,
            recoveryStatus: CrossAppLevel = .unknown,
            workoutPlannedToday: Bool? = nil,
            workoutCompletedToday: Bool? = nil,
            nutritionStatus: CrossAppLevel = .unknown,
            calorieStatus: CrossAppLevel = .unknown,
            dailyChecklistCompletion: Double? = nil,
            importantHealthTasksDue: [ImportantHealthTask]? = nil
        ) {
            self.sleepScore = sleepScore
            self.energyLevel = energyLevel
            self.recoveryStatus = recoveryStatus
            self.workoutPlannedToday = workoutPlannedToday
            self.workoutCompletedToday = workoutCompletedToday
            self.nutritionStatus = nutritionStatus
            self.calorieStatus = calorieStatus
            self.dailyChecklistCompletion = dailyChecklistCompletion
            self.importantHealthTasksDue = importantHealthTasksDue
        }

        /// Every field decoded independently with `try?`, so one malformed
        /// value (an unexpected type, a missing key) never fails the rest
        /// of the snapshot. The four level fields fall back to `.unknown`,
        /// via `CrossAppLevel.init(from:)`, whether the raw value is
        /// unrecognized or the key is missing entirely.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sleepScore = try? c.decodeIfPresent(Int.self, forKey: .sleepScore)
            energyLevel = Self.decodeLevel(c, .energyLevel)
            recoveryStatus = Self.decodeLevel(c, .recoveryStatus)
            workoutPlannedToday = try? c.decodeIfPresent(Bool.self, forKey: .workoutPlannedToday)
            workoutCompletedToday = try? c.decodeIfPresent(Bool.self, forKey: .workoutCompletedToday)
            nutritionStatus = Self.decodeLevel(c, .nutritionStatus)
            calorieStatus = Self.decodeLevel(c, .calorieStatus)
            dailyChecklistCompletion = try? c.decodeIfPresent(Double.self, forKey: .dailyChecklistCompletion)
            importantHealthTasksDue = try? c.decodeIfPresent([ImportantHealthTask].self, forKey: .importantHealthTasksDue)
        }

        /// `energyLevel` shares `CrossAppLevel`'s own low/medium/high
        /// vocabulary directly, but LockedInFit's `RecoveryStatus` doesn't:
        /// it encodes poor/okay/good/unknown. Decoding straight through
        /// `CrossAppLevel`'s generic decoder would silently land every real
        /// recovery reading on `.unknown` (poor/okay/good never match
        /// low/medium/high), quietly disabling half of `isLowReadiness`
        /// below; reading the raw string and mapping LockedInFit's actual
        /// vocabulary explicitly avoids that. `nutritionStatus`/
        /// `calorieStatus` use their own, different four/three-value
        /// vocabularies too (currently unused by any logic here) and are
        /// left decoding via the generic path: `.unknown` until someone
        /// defines what they should mean here, rather than guessing a
        /// mapping with no consumer to verify it against.
        private static func decodeLevel(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> CrossAppLevel {
            guard key == .energyLevel || key == .recoveryStatus else {
                guard let value = try? container.decodeIfPresent(CrossAppLevel.self, forKey: key) else { return .unknown }
                return value ?? .unknown
            }
            guard let raw = ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil) else { return .unknown }
            switch raw.lowercased() {
            case "low", "poor": return .low
            case "medium", "okay": return .medium
            case "high", "good": return .high
            default: return .unknown
            }
        }
    }

    /// Decodes a snapshot, returning `nil` for anything missing, stale in
    /// shape, or corrupted rather than throwing. Callers should treat `nil`
    /// exactly like "LockedInFit isn't installed."
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
        (importantHealthTasksDue?.count ?? 0) >= 3
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
        if energyLevel != .unknown {
            return "Energy: \(energyLevel.rawValue). Showing normal social reminders."
        }
        return "Showing normal social reminders."
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
