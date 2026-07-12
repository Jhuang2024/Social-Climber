import Foundation
import Observation

/// A tiny shared bus for "a notification action wants the app to open
/// somewhere". The action handler sets `pending`; `RootTabView` observes it and
/// navigates, then clears it. Keeps notification handling decoupled from view
/// code.
@Observable
@MainActor
final class NotificationRouter {
    static let shared = NotificationRouter()
    private init() {}

    enum Destination: Equatable {
        case reminders
        case captureReview
        case contact(name: String)
        case logInteraction(personName: String?)
    }

    var pending: Destination?

    func request(_ destination: Destination) {
        pending = destination
    }
}
