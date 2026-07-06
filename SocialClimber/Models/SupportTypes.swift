import SwiftUI

enum PersonCategory: String, Codable, CaseIterable, Identifiable {
    case family
    case closeFriend
    case friend
    case roommate
    case classmate
    case mentor
    case professional
    case acquaintance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .family: "Family"
        case .closeFriend: "Close Friend"
        case .friend: "Friend"
        case .roommate: "Roommate"
        case .classmate: "Classmate"
        case .mentor: "Mentor"
        case .professional: "Professional"
        case .acquaintance: "Acquaintance"
        }
    }

    var icon: String {
        switch self {
        case .family: "house.fill"
        case .closeFriend: "heart.fill"
        case .friend: "person.2.fill"
        case .roommate: "bed.double.fill"
        case .classmate: "graduationcap.fill"
        case .mentor: "lightbulb.fill"
        case .professional: "briefcase.fill"
        case .acquaintance: "person.fill"
        }
    }

    var color: Color {
        switch self {
        case .family: .orange
        case .closeFriend: .pink
        case .friend: .blue
        case .roommate: .teal
        case .classmate: .indigo
        case .mentor: .purple
        case .professional: .brown
        case .acquaintance: .gray
        }
    }
}

enum RelationshipStatus: String, Codable, CaseIterable, Identifiable {
    case good
    case checkInSoon
    case goingQuiet
    case dormant
    case archived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .good: "Good"
        case .checkInSoon: "Check In Soon"
        case .goingQuiet: "Going Quiet"
        case .dormant: "Dormant"
        case .archived: "Archived"
        }
    }

    var color: Color {
        switch self {
        case .good: .green
        case .checkInSoon: .yellow
        case .goingQuiet: .orange
        case .dormant: .red
        case .archived: .gray
        }
    }

    var icon: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .checkInSoon: "clock.fill"
        case .goingQuiet: "moon.fill"
        case .dormant: "zzz"
        case .archived: "archivebox.fill"
        }
    }
}

enum InteractionType: String, Codable, CaseIterable, Identifiable {
    case inPerson
    case call
    case message
    case videoCall
    case event
    case socialMedia
    case email
    case favor
    case intro
    case voiceNote
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inPerson: "In Person"
        case .call: "Call"
        case .message: "Text"
        case .videoCall: "Video Call"
        case .event: "Event"
        case .socialMedia: "Social Media"
        case .email: "Email"
        case .favor: "Favor"
        case .intro: "Intro"
        case .voiceNote: "Voice Note"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .inPerson: "figure.2"
        case .call: "phone.fill"
        case .message: "message.fill"
        case .videoCall: "video.fill"
        case .event: "party.popper.fill"
        case .socialMedia: "bubble.left.and.text.bubble.right.fill"
        case .email: "envelope.fill"
        case .favor: "hands.sparkles.fill"
        case .intro: "person.line.dotted.person.fill"
        case .voiceNote: "waveform"
        case .other: "ellipsis.circle.fill"
        }
    }

    /// Types offered in the manual "Log Interaction" picker (voice notes have
    /// their own capture flow, so they're excluded here).
    static var loggable: [InteractionType] {
        allCases.filter { $0 != .voiceNote }
    }
}

/// A four-level sentiment for an interaction. Backed by the existing 1–5
/// `quality` integer so no data migration is needed and the relationship
/// score keeps working — sentiment is just a friendlier face on quality.
enum Sentiment: Int, CaseIterable, Identifiable {
    case bad = 1
    case neutral = 2
    case good = 3
    case great = 4

    var id: Int { rawValue }

    /// The 1–5 quality value this sentiment maps onto.
    var quality: Int {
        switch self {
        case .bad: 1
        case .neutral: 3
        case .good: 4
        case .great: 5
        }
    }

    init(quality: Int) {
        switch quality {
        case ..<3: self = .bad
        case 3: self = .neutral
        case 4: self = .good
        default: self = .great
        }
    }

    var label: String {
        switch self {
        case .bad: "Bad"
        case .neutral: "Neutral"
        case .good: "Good"
        case .great: "Great"
        }
    }

    var emoji: String {
        switch self {
        case .bad: "😕"
        case .neutral: "😐"
        case .good: "🙂"
        case .great: "🤩"
        }
    }

    var icon: String {
        switch self {
        case .bad: "hand.thumbsdown.fill"
        case .neutral: "minus.circle.fill"
        case .good: "hand.thumbsup.fill"
        case .great: "star.fill"
        }
    }

    var color: Color {
        switch self {
        case .bad: .red
        case .neutral: .gray
        case .good: .green
        case .great: .yellow
        }
    }
}

/// Where an imported social-media message came from.
enum MessagePlatform: String, Codable, CaseIterable, Identifiable {
    case instagram
    case iMessage
    case snapchat
    case whatsApp
    case weChat
    case linkedIn
    case discord
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instagram: "Instagram"
        case .iMessage: "iMessage"
        case .snapchat: "Snapchat"
        case .whatsApp: "WhatsApp"
        case .weChat: "WeChat"
        case .linkedIn: "LinkedIn"
        case .discord: "Discord"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .instagram: "camera.fill"
        case .iMessage: "message.fill"
        case .snapchat: "bolt.fill"
        case .whatsApp: "phone.circle.fill"
        case .weChat: "bubble.left.and.bubble.right.fill"
        case .linkedIn: "briefcase.fill"
        case .discord: "gamecontroller.fill"
        case .other: "ellipsis.bubble.fill"
        }
    }

    var color: Color {
        switch self {
        case .instagram: .pink
        case .iMessage: .green
        case .snapchat: .yellow
        case .whatsApp: .green
        case .weChat: .green
        case .linkedIn: .blue
        case .discord: .indigo
        case .other: .gray
        }
    }
}

enum ReminderType: String, Codable, CaseIterable, Identifiable {
    case checkIn
    case birthday
    case gift
    case followUp
    case hangout
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .checkIn: "Check In"
        case .birthday: "Birthday"
        case .gift: "Gift"
        case .followUp: "Follow Up"
        case .hangout: "Hangout"
        case .custom: "Custom"
        }
    }

    var icon: String {
        switch self {
        case .checkIn: "bubble.left.and.bubble.right.fill"
        case .birthday: "birthday.cake.fill"
        case .gift: "gift.fill"
        case .followUp: "arrow.uturn.right.circle.fill"
        case .hangout: "figure.2.arms.open"
        case .custom: "bell.fill"
        }
    }

    var color: Color {
        switch self {
        case .checkIn: .blue
        case .birthday: .pink
        case .gift: .purple
        case .followUp: .orange
        case .hangout: .teal
        case .custom: .gray
        }
    }
}

enum GiftStatus: String, Codable, CaseIterable, Identifiable {
    case idea
    case planned
    case purchased
    case given

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idea: "Idea"
        case .planned: "Planned"
        case .purchased: "Purchased"
        case .given: "Given"
        }
    }

    var icon: String {
        switch self {
        case .idea: "lightbulb"
        case .planned: "cart"
        case .purchased: "checkmark.seal"
        case .given: "gift.fill"
        }
    }

    var color: Color {
        switch self {
        case .idea: .yellow
        case .planned: .blue
        case .purchased: .green
        case .given: .purple
        }
    }
}

struct ContactMethod: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var label: String   // "Phone", "Email", "Instagram", ...
    var value: String
}

extension Date {
    var daysFromNow: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: self)).day ?? 0
    }

    var daysAgo: Int { -daysFromNow }

    /// Next yearly occurrence of this date's month/day, today or later.
    var nextYearlyOccurrence: Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.month, .day], from: self)
        comps.hour = 0
        return cal.nextDate(after: cal.startOfDay(for: .now).addingTimeInterval(-1), matching: comps, matchingPolicy: .nextTimePreservingSmallerComponents) ?? self
    }

    var shortFormat: String { formatted(date: .abbreviated, time: .omitted) }

    var relativeLabel: String {
        let days = daysAgo
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 30 { return "\(days / 7)w ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }
}
