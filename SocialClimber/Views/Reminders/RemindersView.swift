import SwiftUI
import SwiftData

struct RemindersView: View {
    @Query(sort: \Reminder.dueDate) private var reminders: [Reminder]
    @Environment(\.modelContext) private var context

    @State private var showCompleted = false
    @State private var showAdd = false

    private var open: [Reminder] { reminders.filter { !$0.completed } }
    private var completed: [Reminder] { reminders.filter(\.completed) }

    private var overdue: [Reminder] { open.filter { $0.dueDate.daysFromNow < 0 } }
    private var today: [Reminder] { open.filter { $0.dueDate.daysFromNow == 0 } }
    private var thisWeek: [Reminder] { open.filter { (1...7).contains($0.dueDate.daysFromNow) } }
    private var later: [Reminder] { open.filter { $0.dueDate.daysFromNow > 7 } }

    var body: some View {
        List {
            Picker("Show", selection: $showCompleted) {
                Text("Open").tag(false)
                Text("Done").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if showCompleted {
                if completed.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "Nothing completed yet",
                        message: "Reminders you check off will show up here."
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(completed) { reminder in
                        ReminderRowView(reminder: reminder)
                            .listRowSeparator(.hidden)
                            .listRowBackground(SCTheme.cardBackground)
                    }
                    .onDelete { offsets in
                        delete(offsets.map { completed[$0] })
                    }
                }
            } else {
                if open.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle.fill",
                        title: "All caught up",
                        message: "No open reminders. Add one for a follow-up, birthday nudge, or plan.",
                        actionTitle: "Add Reminder"
                    ) { showAdd = true }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    section("Overdue", overdue)
                    section("Today", today)
                    section("This Week", thisWeek)
                    section("Later", later)
                }
            }
        }
        .listStyle(.insetGrouped)
        .socialClimberPageBackground()
        .navigationTitle("Reminders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { ReminderEditSheet() }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Reminder]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { reminder in
                    ReminderRowView(reminder: reminder)
                        .listRowSeparator(.hidden)
                        .listRowBackground(SCTheme.cardBackground)
                }
                .onDelete { offsets in
                    delete(offsets.map { items[$0] })
                }
            }
        }
    }

    private func delete(_ items: [Reminder]) {
        for item in items {
            NotificationService.shared.cancel(reminder: item)
            context.delete(item)
        }
    }
}

#Preview {
    NavigationStack { RemindersView() }
        .modelContainer(PreviewData.container)
}
