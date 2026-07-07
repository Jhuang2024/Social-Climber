import SwiftUI
import SwiftData

struct EventDetailView: View {
    @Bindable var event: Event
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showEdit = false
    @State private var showLog = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if event.needsLogging {
                    Button { showLog = true } label: {
                        Label("Log interactions for attendees", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.primaryCTA)
                } else if event.loggedAt != nil {
                    Label("Interactions logged \(event.loggedAt!.relativeLabel)", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
                }

                if !event.purpose.isEmpty {
                    FormSectionCard("Purpose", icon: "target") {
                        Text(event.purpose).font(.subheadline)
                    }
                }
                if !event.notes.isEmpty {
                    FormSectionCard("Notes", icon: "note.text") {
                        Text(event.notes).font(.subheadline)
                    }
                }

                FormSectionCard("Attendees", icon: "person.2") {
                    if event.attendees.isEmpty {
                        Text("No attendees linked yet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(event.attendees, id: \.persistentModelID) { person in
                            NavigationLink(value: person) {
                                HStack {
                                    PersonAvatarView(person: person, size: 36)
                                    Text(person.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { showLog = true } label: {
                        Label("Log interaction", systemImage: "plus.bubble")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(event.attendees.isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle(event.name.isEmpty ? "Event" : event.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) { EventEditView(event: event) }
        .sheet(isPresented: $showLog) { EventLogView(event: event) }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                context.delete(event)
                dismiss()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "party.popper.fill")
                .font(.title)
                .foregroundStyle(SCTheme.accent)
                .frame(width: 64, height: 64)
                .background(SCTheme.accent.opacity(0.12), in: Circle())
            Text(event.date.formatted(date: .complete, time: .shortened))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !event.location.isEmpty {
                Label(event.location, systemImage: "mappin.and.ellipse")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
    }
}

/// Quickly log a group interaction for an event's attendees, with an optional
/// follow-up reminder created for each selected person.
struct EventLogView: View {
    let event: Event
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var included: Set<PersistentIdentifier> = []
    @State private var sentiment: Sentiment = .good
    @State private var note = ""
    @State private var followUpNeeded = false
    @State private var followUpDate = Calendar.current.date(byAdding: .day, value: 5, to: .now) ?? .now
    @State private var nextMove = ""

    private var selectedPeople: [Person] {
        event.attendees.filter { included.contains($0.persistentModelID) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Attendees") {
                    ForEach(event.attendees, id: \.persistentModelID) { person in
                        Button {
                            toggle(person)
                        } label: {
                            HStack {
                                PersonAvatarView(person: person, size: 30)
                                Text(person.displayName).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: included.contains(person.persistentModelID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(included.contains(person.persistentModelID) ? SCTheme.accent : .secondary)
                            }
                        }
                    }
                }
                Section("How was it?") {
                    SentimentPicker(sentiment: $sentiment)
                    TextField("Note (shared across attendees)", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Follow-up") {
                    Toggle("Create a follow-up for each", isOn: $followUpNeeded.animation(.snappy))
                    if followUpNeeded {
                        DatePicker("Follow up by", selection: $followUpDate, displayedComponents: .date)
                        TextField("Next move", text: $nextMove, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .navigationTitle("Log Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(selectedPeople.isEmpty)
                }
            }
            .onAppear {
                if included.isEmpty { included = Set(event.attendees.map(\.persistentModelID)) }
            }
            .keyboardDoneButton()
        }
    }

    private func toggle(_ person: Person) {
        let id = person.persistentModelID
        if included.contains(id) { included.remove(id) } else { included.insert(id) }
    }

    private func save() {
        let people = selectedPeople
        guard !people.isEmpty else { return }
        let summary = "At \(event.name)" + (note.isEmpty ? "" : ": \(note)")
        let interaction = Interaction(
            type: .event,
            date: event.date,
            location: event.location,
            note: note,
            quality: sentiment.quality,
            messageSummary: summary
        )
        interaction.people = people
        context.insert(interaction)
        InteractionSaver.applyClosenessImpact(of: interaction, to: people)
        for person in people {
            person.markContacted(type: .event, date: event.date)
        }
        // A follow-up reminder for each attendee, if requested.
        if followUpNeeded {
            for person in people {
                let title = nextMove.isEmpty ? "Follow up with \(person.firstName) after \(event.name)" : nextMove
                let reminder = Reminder(title: title, dueDate: followUpDate, type: .followUp, person: person, notes: nextMove)
                context.insert(reminder)
                NotificationService.shared.schedule(reminder: reminder)
            }
        }
        event.loggedAt = .now
        Haptics.success()
        dismiss()
    }
}

#Preview {
    NavigationStack {
        EventDetailView(event: {
            let e = Event(name: "Sample dinner", date: .now, location: "Home")
            return e
        }())
        .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
    }
    .modelContainer(PreviewData.container)
}
