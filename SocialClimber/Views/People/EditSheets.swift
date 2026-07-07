import SwiftUI
import SwiftData

/// Small add sheets for gifts, reminders, and important dates.

struct GiftIdeaEditSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var person: Person?

    @Query(sort: \Person.name) private var people: [Person]
    @State private var selectedPerson: Person?
    @State private var title = ""
    @State private var notes = ""
    @State private var priceRange = ""
    @State private var occasion = ""
    @State private var status: GiftStatus = .idea

    var body: some View {
        NavigationStack {
            Form {
                TextField("Gift idea", text: $title)
                    .submitLabel(.done)
                if person == nil {
                    Picker("For", selection: $selectedPerson) {
                        Text("No one specific").tag(Person?.none)
                        ForEach(people.filter { !$0.isArchived }) { p in
                            Text(p.displayName).tag(Person?.some(p))
                        }
                    }
                }
                TextField("Occasion (e.g. Birthday)", text: $occasion)
                    .submitLabel(.done)
                TextField("Price range (e.g. $30–50)", text: $priceRange)
                    .submitLabel(.done)
                Picker("Status", selection: $status) {
                    ForEach(GiftStatus.allCases) { Text($0.label).tag($0) }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneToolbar()
            .navigationTitle("Gift Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let gift = GiftIdea(title: title, person: person ?? selectedPerson, notes: notes, priceRange: priceRange, occasion: occasion, status: status)
                        context.insert(gift)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ReminderEditSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var person: Person?

    @Query(sort: \Person.name) private var people: [Person]
    @State private var selectedPerson: Person?
    @State private var title = ""
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var type: ReminderType = .checkIn
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Reminder", text: $title)
                    .submitLabel(.done)
                if person == nil {
                    Picker("Person", selection: $selectedPerson) {
                        Text("No one specific").tag(Person?.none)
                        ForEach(people.filter { !$0.isArchived }) { p in
                            Text(p.displayName).tag(Person?.some(p))
                        }
                    }
                }
                DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                Picker("Type", selection: $type) {
                    ForEach(ReminderType.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneToolbar()
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let reminder = Reminder(title: title, dueDate: dueDate, type: type, person: person ?? selectedPerson, notes: notes)
                        context.insert(reminder)
                        NotificationService.shared.schedule(reminder: reminder)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ImportantDateEditSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var person: Person?

    @Query(sort: \Person.name) private var people: [Person]
    @State private var selectedPerson: Person?
    @State private var title = ""
    @State private var date = Date.now
    @State private var repeatsYearly = true
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title (e.g. Anniversary, Graduation)", text: $title)
                    .submitLabel(.done)
                if person == nil {
                    Picker("Person", selection: $selectedPerson) {
                        Text("No one specific").tag(Person?.none)
                        ForEach(people.filter { !$0.isArchived }) { p in
                            Text(p.displayName).tag(Person?.some(p))
                        }
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Toggle("Repeats yearly", isOn: $repeatsYearly)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneToolbar()
            .navigationTitle("Important Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let important = ImportantDate(title: title, date: date, repeatsYearly: repeatsYearly, person: person ?? selectedPerson, notes: notes)
                        context.insert(important)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
