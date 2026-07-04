import SwiftUI

// MARK: - ReminderRowView

struct ReminderRowView: View {
    @Bindable var reminder: Reminder
    var showPerson = true

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation {
                    reminder.completed.toggle()
                    if reminder.completed {
                        NotificationService.shared.cancel(reminder: reminder)
                    } else {
                        NotificationService.shared.schedule(reminder: reminder)
                    }
                }
            } label: {
                Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.completed ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.body)
                    .strikethrough(reminder.completed, color: .secondary)
                    .foregroundStyle(reminder.completed ? .secondary : .primary)
                HStack(spacing: 6) {
                    if showPerson, let person = reminder.person {
                        Text(person.firstName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(reminder.dueDate.shortFormat)
                        .font(.caption)
                        .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                }
            }
            Spacer()
            Image(systemName: reminder.type.icon)
                .font(.caption)
                .foregroundStyle(reminder.type.color)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - GiftIdeaRowView

struct GiftIdeaRowView: View {
    @Bindable var gift: GiftIdea
    var showPerson = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.body)
                .foregroundStyle(gift.status.color)
                .frame(width: 32, height: 32)
                .background(gift.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(gift.title)
                    .font(.body)
                HStack(spacing: 6) {
                    if showPerson, let person = gift.person {
                        Text("For \(person.firstName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !gift.occasion.isEmpty {
                        Text(gift.occasion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !gift.priceRange.isEmpty {
                        Text(gift.priceRange)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Menu {
                ForEach(GiftStatus.allCases) { status in
                    Button {
                        gift.status = status
                    } label: {
                        Label(status.label, systemImage: status.icon)
                    }
                }
            } label: {
                Text(gift.status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(gift.status.color.opacity(0.12), in: Capsule())
                    .foregroundStyle(gift.status.color)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - TimelineRowView

struct TimelineRowView: View {
    let interaction: Interaction
    var showPeople = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: interaction.type.icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(showPeople && !interaction.people.isEmpty ? interaction.peopleNames : interaction.type.label)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(interaction.date.relativeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !interaction.note.isEmpty {
                    Text(interaction.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !interaction.topics.isEmpty {
                    Text(interaction.topics.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if interaction.followUpNeeded {
                    Label("Follow-up needed", systemImage: "arrow.uturn.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PersonRowView

struct PersonRowView: View {
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            PersonAvatarView(person: person, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.displayName)
                        .font(.body.weight(.medium))
                    if !person.nickname.isEmpty && person.nickname != person.name {
                        Text("“\(person.nickname)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(person.relationshipToMe.isEmpty ? person.category.label : person.relationshipToMe)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                RelationshipStatusBadge(status: person.status, compact: true)
                if let days = RelationshipHealth.daysSinceContact(for: person) {
                    Text(days == 0 ? "Today" : "\(days)d")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
