import SwiftUI
import SwiftData

/// List of social opportunities, split into upcoming and past. Pushed inside a
/// NavigationStack that provides `navigationDestination(for: Person.self)`.
struct EventsListView: View {
    @Query(sort: \Event.date, order: .reverse) private var events: [Event]
    @State private var showAdd = false

    private var upcoming: [Event] {
        events.filter { $0.isUpcoming }.sorted { $0.date < $1.date }
    }
    private var past: [Event] {
        events.filter { !$0.isUpcoming }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if events.isEmpty {
                    EmptyStateView(
                        icon: "calendar.badge.plus",
                        title: "No events yet",
                        message: "Track parties, dinners, and meetups. After an event you can log interactions for everyone at once.",
                        actionTitle: "Add Event"
                    ) { showAdd = true }
                } else {
                    if !upcoming.isEmpty {
                        FormSectionCard("Upcoming", icon: "calendar") {
                            ForEach(upcoming, id: \.persistentModelID) { event in
                                eventRow(event)
                            }
                        }
                    }
                    if !past.isEmpty {
                        FormSectionCard("Past", icon: "clock.arrow.circlepath") {
                            ForEach(past, id: \.persistentModelID) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { EventEditView() }
    }

    private func eventRow(_ event: Event) -> some View {
        NavigationLink {
            EventDetailView(event: event)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 1) {
                    Text(event.date.formatted(.dateTime.month(.abbreviated)))
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                    Text(event.date.formatted(.dateTime.day()))
                        .font(.title3.weight(.bold))
                }
                .frame(width: 46, height: 46)
                .background(SCTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(SCTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.name.isEmpty ? "Untitled event" : event.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !event.attendees.isEmpty {
                        Text(event.attendeeNames)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if event.needsLogging {
                    Text("Log")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

/// Create or edit an event.
struct EventEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var event: Event?

    @State private var name = ""
    @State private var date = Date.now
    @State private var location = ""
    @State private var purpose = ""
    @State private var notes = ""
    @State private var attendees: [Person] = []
    @State private var showPeoplePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Name (e.g. Dinner party)", text: $name)
                    DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Location", text: $location)
                }
                Section("Details") {
                    TextField("Purpose (e.g. reconnect with old friends)", text: $purpose, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Attendees") {
                    if attendees.isEmpty {
                        Button { showPeoplePicker = true } label: {
                            Label("Add attendees", systemImage: "person.2.badge.plus")
                        }
                    } else {
                        ForEach(attendees) { person in
                            HStack {
                                PersonAvatarView(person: person, size: 30)
                                Text(person.displayName)
                                Spacer()
                            }
                        }
                        .onDelete { attendees.remove(atOffsets: $0) }
                        Button { showPeoplePicker = true } label: {
                            Label("Add / remove attendees", systemImage: "person.2.badge.plus")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .navigationTitle(event == nil ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showPeoplePicker) {
                NavigationStack {
                    PersonMultiPicker(selected: $attendees)
                        .navigationTitle("Attendees")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showPeoplePicker = false }
                            }
                        }
                }
            }
            .onAppear(perform: load)
            .keyboardDoneButton()
        }
    }

    private func load() {
        guard let event else { return }
        name = event.name
        date = event.date
        location = event.location
        purpose = event.purpose
        notes = event.notes
        attendees = event.attendees
    }

    private func save() {
        if let event {
            event.name = name
            event.date = date
            event.location = location
            event.purpose = purpose
            event.notes = notes
            event.attendees = attendees
        } else {
            let new = Event(name: name, date: date, location: location, purpose: purpose, notes: notes, attendees: attendees)
            context.insert(new)
        }
        Haptics.success()
        dismiss()
    }
}

#Preview {
    NavigationStack {
        EventsListView()
            .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
    }
    .modelContainer(PreviewData.container)
}
