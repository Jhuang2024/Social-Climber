import Foundation
import EventKit

/// Optional, read-only calendar integration: finds upcoming events that
/// mention known people so they can be turned into planned hangouts.
@Observable
final class CalendarService {
    static let shared = CalendarService()
    private let store = EKEventStore()

    var authorized = false

    private init() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        if authorized { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        await MainActor.run { authorized = granted }
        return granted
    }

    struct MatchedEvent: Identifiable {
        let id: String
        let title: String
        let date: Date
        let people: [Person]
    }

    /// Events in the next `days` days whose title or attendees mention a known person.
    func upcomingEvents(matching people: [Person], days: Int = 30) -> [MatchedEvent] {
        guard authorized else { return [] }
        let start = Date.now
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        return events.compactMap { event in
            let haystack = (
                (event.title ?? "") + " " +
                (event.attendees?.compactMap(\.name).joined(separator: " ") ?? "")
            ).lowercased()
            let matched = people.filter { person in
                !person.firstName.isEmpty && haystack.contains(person.firstName.lowercased())
            }
            guard !matched.isEmpty, let date = event.startDate else { return nil }
            return MatchedEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Event",
                date: date,
                people: matched
            )
        }
        .sorted { $0.date < $1.date }
    }
}
