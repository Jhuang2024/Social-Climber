import Foundation

/// The shared low/medium/high/unknown vocabulary used on both sides of the
/// Social Climber <-> LockedInFit bridge: Social Climber's own
/// `socialIntensity`/`importance` fields, and LockedInFit's
/// `energyLevel`/`recoveryStatus`/`nutritionStatus`/`calorieStatus`. A
/// missing or unrecognized raw value never fails the decode: it resolves to
/// `.unknown`, the shared "we don't know" case, instead of throwing and
/// losing the rest of the file.
enum CrossAppLevel: String, Codable, Equatable {
    case low
    case medium
    case high
    case unknown

    init(from decoder: Decoder) throws {
        guard let raw = try? decoder.singleValueContainer().decode(String.self) else {
            self = .unknown
            return
        }
        self = CrossAppLevel(rawValue: raw.lowercased()) ?? .unknown
    }
}

extension CrossAppLevel {
    init(_ level: ImportanceLevel) {
        switch level {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }

    /// Used only to pick "the most intense" value out of several (e.g. the
    /// highest social intensity among today's events); `.unknown` never wins.
    private var rank: Int {
        switch self {
        case .unknown: -1
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func highest(of levels: [CrossAppLevel], defaultingTo fallback: CrossAppLevel) -> CrossAppLevel {
        levels.max { $0.rank < $1.rank } ?? fallback
    }
}
