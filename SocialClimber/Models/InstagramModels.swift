import Foundation
import SwiftUI
import SwiftData

/// One point-in-time capture of the Instagram follower/following lists,
/// taken from a "Download Your Information" export each time a sync runs.
/// Snapshots exist so consecutive syncs can be diffed: that diff is what
/// produces `FollowerEvent`s. Only usernames are stored, nothing else from
/// the export is persisted here.
@Model
final class FollowerSnapshot {
    var takenAt: Date = Date()
    var followerUsernames: [String] = []
    var followingUsernames: [String] = []

    init(takenAt: Date = .now, followerUsernames: [String], followingUsernames: [String]) {
        self.takenAt = takenAt
        self.followerUsernames = followerUsernames
        self.followingUsernames = followingUsernames
    }
}

enum FollowerEventKind: String, Codable, CaseIterable, Identifiable {
    case gainedFollower
    case lostFollower
    case startedFollowing
    case stoppedFollowing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gainedFollower: "New follower"
        case .lostFollower: "Unfollowed you"
        case .startedFollowing: "You followed"
        case .stoppedFollowing: "You unfollowed"
        }
    }

    var icon: String {
        switch self {
        case .gainedFollower: "person.badge.plus"
        case .lostFollower: "person.badge.minus"
        case .startedFollowing: "plus.circle"
        case .stoppedFollowing: "minus.circle"
        }
    }

    /// Drawn from the app's curated accent set rather than stock SwiftUI
    /// colors, so follower events read as part of the same product as the
    /// rest of the dashboard.
    var color: Color {
        switch self {
        case .gainedFollower: SCTheme.Accents.growth
        case .lostFollower: SCTheme.Accents.alert
        case .startedFollowing: SCTheme.Accents.cool
        case .stoppedFollowing: SCTheme.Accents.warm
        }
    }
}

/// A single detected change between two follower snapshots: someone
/// followed or unfollowed you (or you them). Persisted separately from the
/// snapshots so history survives snapshot pruning.
@Model
final class FollowerEvent {
    var username: String = ""
    var kindRaw: String = FollowerEventKind.gainedFollower.rawValue
    var date: Date = Date()

    init(username: String, kind: FollowerEventKind, date: Date = .now) {
        self.username = username
        self.kindRaw = kind.rawValue
        self.date = date
    }

    var kind: FollowerEventKind {
        get { FollowerEventKind(rawValue: kindRaw) ?? .gainedFollower }
        set { kindRaw = newValue.rawValue }
    }
}
