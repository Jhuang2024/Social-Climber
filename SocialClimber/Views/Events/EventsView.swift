import SwiftUI
import SwiftData
import UIKit

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

    // Fit Checker: event-prep assistance only. Never saved to the event or
    // to any person; purely local to this sheet's session.
    @State private var fitCheckImages: [UIImage] = []
    @State private var isCheckingFit = false
    @State private var fitResult: FitCheckResult?
    @State private var fitNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Name (e.g. Dinner party)", text: $name)
                        .submitLabel(.done)
                    DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Location", text: $location)
                        .submitLabel(.done)
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
                fitCheckSection
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
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
            .onChange(of: fitCheckImages) { _, _ in
                fitResult = nil
                fitNotice = nil
            }
            .keyboardDoneButton()
        }
    }

    // MARK: Fit Checker

    private var fitCheckSection: some View {
        Section {
            PhotoInputControl(
                images: $fitCheckImages,
                maxCount: 1,
                placeholderIcon: "tshirt",
                placeholderText: "Add a photo of your outfit"
            )
            if !fitCheckImages.isEmpty {
                Button {
                    Task { await checkFit() }
                } label: {
                    if isCheckingFit {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Analyzing your fit…")
                        }
                    } else {
                        Label(fitResult == nil ? "Check My Fit" : "Re-check Fit", systemImage: "sparkles")
                    }
                }
                .disabled(isCheckingFit)
            }
            if let fitNotice {
                Label(fitNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let fitResult {
                FitCheckResultCard(result: fitResult)
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
            }
        } header: {
            Text("Fit Checker")
        } footer: {
            Text("Optional. Rates your outfit for this event using AI; the photo and result are never saved, and this never affects closeness, interactions, or relationship scores.")
        }
    }

    private func checkFit() async {
        guard let image = fitCheckImages.first else { return }
        isCheckingFit = true
        fitNotice = nil
        let ctx = FitCheckEngine.EventContext(title: name, date: date, location: location, purpose: purpose, notes: notes, attendees: attendees)
        let outcome = await FitCheckEngine.check(image: image, context: ctx)
        fitResult = outcome.result
        fitNotice = outcome.notice
        isCheckingFit = false
        if outcome.result != nil { Haptics.success() }
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
        let target: Event
        if let event {
            event.name = name
            event.date = date
            event.location = location
            event.purpose = purpose
            event.notes = notes
            event.attendees = attendees
            target = event
        } else {
            let new = Event(name: name, date: date, location: location, purpose: purpose, notes: notes, attendees: attendees)
            context.insert(new)
            target = new
        }
        NotificationService.shared.schedule(event: target)
        Haptics.success()
        dismiss()
    }
}

/// Displays a `FitCheckResult`: a score ring, verdict, and the
/// strengths/weak-points/improvements lists, used only inside
/// `EventEditView`'s Fit Checker section.
private struct FitCheckResultCard: View {
    let result: FitCheckResult

    private var scoreColor: Color {
        switch result.score {
        case 80...: .green
        case 60..<80: SCTheme.accent
        case 40..<60: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(scoreColor.opacity(0.18), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: CGFloat(result.score) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(result.score)")
                        .font(.headline.weight(.bold))
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Fit Score")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(result.verdict.isEmpty ? "No verdict returned." : result.verdict)
                        .font(.subheadline.weight(.semibold))
                    if let confidence = result.confidence {
                        Text("Confidence: \(Int(confidence * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            if !result.strengths.isEmpty {
                fitList("Strengths", icon: "checkmark.circle.fill", color: .green, items: result.strengths)
            }
            if !result.weaknesses.isEmpty {
                fitList("Weak Points", icon: "exclamationmark.circle.fill", color: .orange, items: result.weaknesses)
            }
            if !result.improvements.isEmpty {
                fitList("Improvements", icon: "arrow.up.circle.fill", color: SCTheme.accent, items: result.improvements)
            }
        }
    }

    private func fitList(_ title: String, icon: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(color)
                        .padding(.top, 2)
                    Text(item)
                        .font(.subheadline)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        EventsListView()
            .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
    }
    .modelContainer(PreviewData.container)
}
