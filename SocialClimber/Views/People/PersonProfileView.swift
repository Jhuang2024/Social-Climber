import SwiftUI
import SwiftData

struct PersonProfileView: View {
    @Bindable var person: Person
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showEdit = false
    @State private var showAddInteraction = false
    @State private var showAddGift = false
    @State private var showAddReminder = false
    @State private var showAddDate = false
    @State private var confirmDelete = false

    private var followUpQuestions: [String] {
        person.sortedInteractions
            .compactMap(\.aiSummary)
            .flatMap(\.followUpQuestions)
            .uniqued()
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                statsRow
                actionsRow

                if !person.notes.isEmpty {
                    FormSectionCard("Notes", icon: "note.text") {
                        Text(person.notes).font(.subheadline)
                    }
                }
                keyFactsCard
                if !person.interests.isEmpty || !person.dislikes.isEmpty {
                    interestsCard
                }
                if !person.personalityNotes.isEmpty {
                    FormSectionCard("Personality", icon: "brain.head.profile") {
                        Text(person.personalityNotes).font(.subheadline)
                    }
                }
                if !followUpQuestions.isEmpty {
                    FormSectionCard("Ask Next Time", icon: "questionmark.bubble") {
                        ForEach(followUpQuestions, id: \.self) { question in
                            Label(question, systemImage: "arrow.turn.down.right")
                                .font(.subheadline)
                        }
                    }
                }
                giftsCard
                datesCard
                remindersCard
                timelineCard
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(person.firstName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button {
                        person.isArchived.toggle()
                    } label: {
                        Label(person.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) { PersonEditView(person: person) }
        .sheet(isPresented: $showAddInteraction) { AddInteractionView(preselected: [person]) }
        .sheet(isPresented: $showAddGift) { GiftIdeaEditSheet(person: person) }
        .sheet(isPresented: $showAddReminder) { ReminderEditSheet(person: person) }
        .sheet(isPresented: $showAddDate) { ImportantDateEditSheet(person: person) }
        .confirmationDialog("Delete \(person.displayName)? This removes all their data.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(person)
                dismiss()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            PersonAvatarView(person: person, size: 92)
            VStack(spacing: 3) {
                Text(person.displayName)
                    .font(.title2.weight(.bold))
                if !person.nickname.isEmpty && person.nickname != person.name {
                    Text("“\(person.nickname)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !person.relationshipToMe.isEmpty {
                    Text(person.relationshipToMe)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                TagPillView(text: person.category.label, color: person.category.color, icon: person.category.icon)
                RelationshipStatusBadge(status: person.status)
            }
            if !person.tags.isEmpty {
                Text(person.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(title: "Closeness", value: dots(person.closeness))
            StatTile(title: "Priority", value: dots(person.priority))
            StatTile(title: "Last Contact", value: person.lastContactedAt?.relativeLabel ?? "Never")
            StatTile(title: "Last Met", value: person.lastMetAt?.relativeLabel ?? "Never")
        }
    }

    private func dots(_ n: Int) -> String {
        String(repeating: "●", count: n) + String(repeating: "○", count: 5 - n)
    }

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button {
                showAddInteraction = true
            } label: {
                Label("Log Interaction", systemImage: "plus.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                person.markContacted(type: .message, date: .now)
            } label: {
                Label("Contacted", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Cards

    private var keyFactsCard: some View {
        FormSectionCard("Key Facts", icon: "info.circle") {
            if let birthday = person.birthday {
                factRow("birthday.cake", "Birthday", birthday.formatted(.dateTime.month(.wide).day()))
            }
            if !person.schoolOrWork.isEmpty {
                factRow("building.2", "School / Work", person.schoolOrWork)
            }
            if !person.location.isEmpty {
                factRow("mappin.and.ellipse", "Location", person.location)
            }
            if !person.familyMembers.isEmpty {
                factRow("figure.2.and.child.holdinghands", "Family", person.familyMembers.joined(separator: ", "))
            }
            ForEach(person.contactMethods) { method in
                factRow("phone", method.label, method.value)
            }
            factRow("clock.arrow.circlepath", "Check-in cadence", "Every \(RelationshipHealth.expectedCadenceDays(for: person)) days")
        }
    }

    private func factRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
    }

    private var interestsCard: some View {
        FormSectionCard("Interests & Dislikes", icon: "heart") {
            if !person.interests.isEmpty {
                TagCloudView(tags: person.interests, color: .green)
            }
            if !person.dislikes.isEmpty {
                TagCloudView(tags: person.dislikes, color: .red)
            }
        }
    }

    private var giftsCard: some View {
        FormSectionCard("Gift Ideas", icon: "gift") {
            if person.giftIdeas.isEmpty {
                Text("No gift ideas yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(person.giftIdeas.sorted { $0.createdAt > $1.createdAt }) { gift in
                    GiftIdeaRowView(gift: gift, showPerson: false)
                }
            }
            Button { showAddGift = true } label: {
                Label("Add gift idea", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var datesCard: some View {
        FormSectionCard("Important Dates", icon: "calendar") {
            if person.importantDates.isEmpty && person.birthday == nil {
                Text("No important dates yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(person.importantDates.sorted { ($0.nextOccurrence ?? .distantFuture) < ($1.nextOccurrence ?? .distantFuture) }) { date in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(date.title).font(.body)
                            if !date.notes.isEmpty {
                                Text(date.notes).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let next = date.nextOccurrence {
                            Text(next.shortFormat)
                                .font(.subheadline)
                                .foregroundStyle(next.daysFromNow <= 14 ? Color.orange : Color.secondary)
                        }
                    }
                }
            }
            Button { showAddDate = true } label: {
                Label("Add date", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var remindersCard: some View {
        FormSectionCard("Reminders", icon: "bell") {
            if person.openReminders.isEmpty {
                Text("Nothing pending.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(person.openReminders) { reminder in
                    ReminderRowView(reminder: reminder, showPerson: false)
                }
            }
            Button { showAddReminder = true } label: {
                Label("Add reminder", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var timelineCard: some View {
        FormSectionCard("Timeline", icon: "clock.arrow.circlepath") {
            if person.sortedInteractions.isEmpty {
                Text("No interactions logged yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(person.sortedInteractions.prefix(10)) { interaction in
                    NavigationLink {
                        InteractionDetailView(interaction: interaction)
                    } label: {
                        TimelineRowView(interaction: interaction, showPeople: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

#Preview {
    NavigationStack {
        PersonProfileView(person: PreviewData.samplePerson)
    }
    .modelContainer(PreviewData.container)
}
