import SwiftUI
import SwiftData

/// Small add sheets for gifts, reminders, and important dates.

/// The "For / Person" picker shared by every add sheet that lets you
/// optionally attach the new item to someone — a plain `Picker` including a
/// "No one specific" option, backed by everyone not archived.
struct OptionalPersonPicker: View {
    let label: String
    let people: [Person]
    @Binding var selection: Person?

    var body: some View {
        Picker(label, selection: $selection) {
            Text("No one specific").tag(Person?.none)
            ForEach(people.filter { !$0.isArchived }) { p in
                Text(p.displayName).tag(Person?.some(p))
            }
        }
    }
}

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
                    OptionalPersonPicker(label: "For", people: people, selection: $selectedPerson)
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
            .navigationTitle("Gift Idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let gift = GiftIdea(title: title, person: person ?? selectedPerson, notes: notes, priceRange: priceRange, occasion: occasion, status: status)
                        context.insert(gift)
                        Haptics.success()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .keyboardDoneButton()
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
                    OptionalPersonPicker(label: "Person", people: people, selection: $selectedPerson)
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
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let reminder = Reminder(title: title, dueDate: dueDate, type: type, person: person ?? selectedPerson, notes: notes)
                        context.insert(reminder)
                        NotificationService.shared.schedule(reminder: reminder)
                        Haptics.success()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .keyboardDoneButton()
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
                    OptionalPersonPicker(label: "Person", people: people, selection: $selectedPerson)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Toggle("Repeats yearly", isOn: $repeatsYearly)
                    .tint(.green)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Important Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let important = ImportantDate(title: title, date: date, repeatsYearly: repeatsYearly, person: person ?? selectedPerson, notes: notes)
                        context.insert(important)
                        NotificationService.shared.schedule(importantDate: important)
                        Haptics.success()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .keyboardDoneButton()
        }
        .presentationDetents([.medium, .large])
    }
}
