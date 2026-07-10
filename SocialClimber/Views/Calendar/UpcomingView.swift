import SwiftUI
import SwiftData

/// Merged feed of everything coming up in the next 60 days: birthdays,
/// important dates, reminders, and (optionally) calendar events that
/// mention known people.
struct UpcomingView: View {
    @Query private var people: [Person]
    @Query private var importantDates: [ImportantDate]
    @Query private var reminders: [Reminder]
    @Environment(\.modelContext) private var context

    @State private var calendarEvents: [GoogleCalendarService.MatchedEvent] = []

    private let windowDays = 60

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let icon: String
        let color: Color
        let title: String
        let subtitle: String
        let person: Person?
        /// Set only when this entry came from an `ImportantDate`, which lets the
        /// row offer a delete swipe action straight back to the source
        /// record, since birthdays/reminders/calendar entries aren't
        /// standalone deletable records the same way.
        var importantDate: ImportantDate? = nil
    }

    private var entries: [Entry] {
        var items: [Entry] = []
        for person in people where !person.isArchived {
            if let next = person.nextBirthday, next.daysFromNow <= windowDays {
                items.append(Entry(date: next, icon: "birthday.cake.fill", color: .pink, title: "\(person.firstName)'s birthday", subtitle: person.relationshipToMe, person: person))
            }
        }
        for date in importantDates {
            if let next = date.nextOccurrence, next.daysFromNow <= windowDays {
                items.append(Entry(date: next, icon: "star.fill", color: .orange, title: date.title, subtitle: date.person?.displayName ?? date.notes, person: date.person, importantDate: date))
            }
        }
        for reminder in reminders where !reminder.completed && reminder.dueDate.daysFromNow <= windowDays {
            items.append(Entry(date: reminder.dueDate, icon: reminder.type.icon, color: reminder.type.color, title: reminder.title, subtitle: reminder.person?.displayName ?? "", person: reminder.person))
        }
        for event in calendarEvents {
            items.append(Entry(date: event.date, icon: "calendar", color: .blue, title: event.title, subtitle: "Calendar · " + event.people.map(\.firstName).joined(separator: ", "), person: event.people.first))
        }
        return items.sorted { $0.date < $1.date }
    }

    private var groupedByWeek: [(String, [Entry])] {
        let groups = Dictionary(grouping: entries) { entry -> String in
            let days = entry.date.daysFromNow
            if days < 0 { return "Overdue" }
            if days == 0 { return "Today" }
            if days <= 7 { return "This Week" }
            if days <= 30 { return "This Month" }
            return "Later"
        }
        let order = ["Overdue", "Today", "This Week", "This Month", "Later"]
        return order.compactMap { key in
            groups[key].map { (key, $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    EmptyStateView(icon: "calendar", title: "Nothing coming up", message: "Birthdays, important dates, plans, and reminders will show here.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(groupedByWeek, id: \.0) { title, items in
                        Section(title) {
                            ForEach(items) { entry in
                                entryRow(entry)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                    .listRowBackground(
                                        RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                                            .fill(SCTheme.cardBackground)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                    )
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .socialClimberPageBackground()
            .navigationTitle("Upcoming")
            .refreshable { await loadCalendar() }
            .task { await loadCalendar() }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon)
                .font(.subheadline)
                .foregroundStyle(entry.color)
                .frame(width: 34, height: 34)
                .background(entry.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold))
                let days = entry.date.daysFromNow
                Text(days == 0 ? "today" : days < 0 ? "\(-days)d ago" : "in \(days)d")
                    .font(.caption2)
                    .foregroundStyle(days <= 7 ? entry.color : .secondary)
            }
        }
        .padding(.vertical, 8)
        .swipeActions(edge: .trailing) {
            if let importantDate = entry.importantDate {
                Button(role: .destructive) {
                    Haptics.warning()
                    context.delete(importantDate)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            if entry.subtitle.hasPrefix("Calendar"), let person = entry.person {
                Button {
                    let reminder = Reminder(title: "Plan: \(entry.title)", dueDate: entry.date, type: .hangout, person: person)
                    context.insert(reminder)
                    NotificationService.shared.schedule(reminder: reminder)
                } label: {
                    Label("Track", systemImage: "plus")
                }
                .tint(.blue)
            }
        }
    }

    private func loadCalendar() async {
        guard GoogleCalendarService.shared.isConnected else {
            calendarEvents = []
            return
        }
        let known = people.filter { !$0.isArchived }
        calendarEvents = await GoogleCalendarService.shared.upcomingEvents(matching: known, days: windowDays)
        // Offer the same post-event "how did it go?" prompt for confidently
        // matched calendar events. The prompt itself never logs anything —
        // an event existing is not contact; it takes one explicit action.
        for event in calendarEvents {
            guard let end = event.endDate else { continue }
            NotificationService.shared.scheduleCalendarFollowUp(
                calendarEventID: event.id,
                title: event.title,
                endDate: end,
                location: "",
                attendeeIDs: event.people.map(\.uuid),
                attendeeNames: event.people.map(\.name)
            )
        }
    }
}

#Preview {
    UpcomingView()
        .modelContainer(PreviewData.container)
}
