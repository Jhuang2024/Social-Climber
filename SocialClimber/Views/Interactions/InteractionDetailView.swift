import SwiftUI
import SwiftData

struct InteractionDetailView: View {
    let interaction: Interaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if !interaction.people.isEmpty {
                    FormSectionCard("With", icon: "person.2") {
                        ForEach(interaction.people) { person in
                            NavigationLink {
                                PersonProfileView(person: person)
                            } label: {
                                HStack {
                                    PersonAvatarView(person: person, size: 36)
                                    Text(person.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !interaction.note.isEmpty {
                    FormSectionCard("Note", icon: "note.text") {
                        Text(interaction.note).font(.subheadline)
                    }
                }

                if !interaction.topics.isEmpty {
                    FormSectionCard("Topics", icon: "tag") {
                        TagCloudView(tags: interaction.topics)
                    }
                }

                if let summary = interaction.aiSummary {
                    summaryCard(summary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle(interaction.type.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog("Delete this interaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                context.delete(interaction)
                dismiss()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: interaction.type.icon)
                .font(.title)
                .foregroundStyle(SCTheme.accent)
                .frame(width: 64, height: 64)
                .background(SCTheme.accent.opacity(0.12), in: Circle())
            Text(interaction.date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !interaction.location.isEmpty {
                Label(interaction.location, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= interaction.quality ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            if interaction.followUpNeeded {
                Label("Follow-up needed", systemImage: "arrow.uturn.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
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

    private func summaryCard(_ summary: ConversationSummary) -> some View {
        FormSectionCard("AI Summary", icon: "sparkles") {
            if !summary.summary.isEmpty {
                Text(summary.summary).font(.subheadline)
            }
            if !summary.interests.isEmpty {
                labeledList("Interests", summary.interests, color: .green)
            }
            if !summary.giftIdeas.isEmpty {
                labeledList("Gift ideas", summary.giftIdeas, color: .purple)
            }
            if !summary.importantDates.isEmpty {
                labeledList("Dates", summary.importantDates, color: .orange)
            }
            if !summary.reminders.isEmpty {
                labeledList("Follow-ups", summary.reminders, color: .blue)
            }
            if !summary.followUpQuestions.isEmpty {
                labeledList("Ask next time", summary.followUpQuestions, color: .teal)
            }
            if !summary.personalityNotes.isEmpty {
                labeledList("Personality", summary.personalityNotes, color: .indigo)
            }
            Text("Confidence \(Int(summary.confidence * 100))%")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func labeledList(_ title: String, _ items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("• \(item)").font(.subheadline)
            }
        }
    }
}

#Preview {
    NavigationStack {
        InteractionDetailView(interaction: {
            let i = Interaction(type: .inPerson, note: "Preview interaction", topics: ["Food"])
            return i
        }())
    }
    .modelContainer(PreviewData.container)
}
