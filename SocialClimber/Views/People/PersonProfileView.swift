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

    private var lastTopics: [String] {
        person.sortedInteractions
            .flatMap(\.topics)
            .filter { !$0.isEmpty }
            .uniqued()
            .prefix(4)
            .map { $0 }
    }

    private var upcomingImportantDates: [ImportantDate] {
        person.importantDates
            .filter { ($0.nextOccurrence?.daysFromNow ?? Int.max) >= 0 }
            .sorted { ($0.nextOccurrence ?? .distantFuture) < ($1.nextOccurrence ?? .distantFuture) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                statsRow
                actionsRow
                beforeMeetingBrief

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
                giftsCard
                datesCard
                remindersCard
                timelineCard
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
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
                Haptics.warning()
                context.delete(person)
                dismiss()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            PersonAvatarView(person: person, size: 92)
            VStack(spacing: 4) {
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
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            LinearGradient(
                colors: [person.category.color.opacity(0.16), SCTheme.cardBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
        .cardShadow()
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            DotStatTile(title: "Closeness", value: person.closeness)
            DotStatTile(title: "Priority", value: person.priority)
            StatTile(title: "Last Contact", value: person.lastContactedAt?.relativeLabel ?? "Never")
            StatTile(title: "Last Met", value: person.lastMetAt?.relativeLabel ?? "Never")
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button {
                showAddInteraction = true
            } label: {
                Label("Log Interaction", systemImage: "plus.bubble")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SCTheme.accent, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(.pressable)

            Button {
                person.markContacted(type: .message, date: .now)
            } label: {
                Label("Contacted", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .sensoryFeedback(.success, trigger: person.lastContactedAt)
        }
    }

    // MARK: Cards

    private var beforeMeetingBrief: some View {
        FormSectionCard("Before Meeting Brief", icon: "person.text.rectangle") {
            briefRow("clock.arrow.circlepath", "Last contacted", person.lastContactedAt?.relativeLabel ?? "Never")
            briefRow("person.2.wave.2", "Last met", person.lastMetAt?.relativeLabel ?? "Never")
            if !lastTopics.isEmpty {
                briefRow("text.bubble", "Last topics", lastTopics.joined(separator: ", "))
            }
            if !person.openReminders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    briefLabel("Open follow-ups", icon: "checklist")
                    ForEach(person.openReminders.prefix(3)) { reminder in
                        Text(reminder.title)
                            .font(.subheadline)
                    }
                }
            }
            if !person.openGiftIdeas.isEmpty {
                briefRow("gift", "Gift ideas", person.openGiftIdeas.prefix(3).map(\.title).joined(separator: ", "))
            }
            if let birthday = person.nextBirthday, birthday.daysFromNow <= 60 {
                briefRow("birthday.cake", "Upcoming birthday", birthday.formatted(.dateTime.month(.wide).day()))
            }
            if !upcomingImportantDates.isEmpty {
                let labels = upcomingImportantDates.prefix(3).compactMap { date -> String? in
                    guard let next = date.nextOccurrence else { return nil }
                    return "\(date.title) \(next.formatted(.dateTime.month(.abbreviated).day()))"
                }
                if !labels.isEmpty {
                    briefRow("calendar", "Important dates", labels.joined(separator: ", "))
                }
            }
            if !followUpQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    briefLabel("Suggested questions", icon: "questionmark.bubble")
                    ForEach(followUpQuestions, id: \.self) { question in
                        Label(question, systemImage: "arrow.turn.down.right")
                            .font(.subheadline)
                    }
                }
            }
            if lastTopics.isEmpty && person.openReminders.isEmpty && person.openGiftIdeas.isEmpty && upcomingImportantDates.isEmpty && followUpQuestions.isEmpty {
                Text("Log an interaction or voice note to build a useful pre-meeting brief.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func briefRow(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            briefLabel(label, icon: icon)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private func briefLabel(_ label: String, icon: String) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

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
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        }
    }
}

private struct DotStatTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 6) {
            DotsRow(value: value, color: SCTheme.accent, size: 6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        }
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
