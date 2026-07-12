import SwiftUI
import SwiftData

struct InteractionDetailView: View {
    @Bindable var interaction: Interaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showEdit = false

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

                if !interaction.messageSummary.isEmpty {
                    FormSectionCard("Summary", icon: "text.quote") {
                        Text(interaction.messageSummary).font(.subheadline)
                    }
                }

                if !interaction.note.isEmpty {
                    FormSectionCard("Note", icon: "note.text") {
                        Text(interaction.note).font(.subheadline)
                    }
                }

                if !interaction.nextMove.isEmpty {
                    FormSectionCard("Next Move", icon: "arrow.turn.up.right") {
                        Text(interaction.nextMove).font(.subheadline)
                    }
                }

                if !interaction.topics.isEmpty {
                    FormSectionCard("Topics", icon: "tag") {
                        TagCloudView(tags: interaction.topics)
                    }
                }

                if interaction.isImported && !interaction.rawImportText.isEmpty {
                    FormSectionCard("Imported Text", icon: "doc.on.clipboard") {
                        Text(interaction.rawImportText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let voiceNote = interaction.aiSummary?.voiceNote, voiceNote.audioFileName != nil {
                    VoiceNotePlaybackView(voiceNote: voiceNote)
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
                Menu {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) { InteractionEditView(interaction: interaction) }
        .confirmationDialog("Delete this interaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                // Capture before deleting: once the interaction is gone,
                // its `people` relationship is nullified along with it.
                let people = interaction.people
                // Undo this interaction's closeness impact before it's gone,
                // otherwise the person's score would keep a "ghost" nudge
                // from an interaction that no longer exists.
                InteractionSaver.reverseClosenessImpact(of: interaction)
                context.delete(interaction)
                // The deleted interaction may have been the one holding a
                // person's "last contacted" date: recompute from what's
                // left instead of leaving it stale.
                for person in people {
                    person.recomputeContactDates()
                }
                dismiss()
            }
            .tint(.red)
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
            HStack(spacing: 8) {
                Text("\(interaction.sentiment.emoji) \(interaction.sentiment.label)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(interaction.sentiment.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(interaction.sentiment.color)
                if let platform = interaction.platform {
                    TagPillView(text: platform.label, color: platform.color, icon: platform.icon)
                }
            }
            if interaction.followUpNeeded {
                let dateText = interaction.followUpDate.map { " by \($0.shortFormat)" } ?? ""
                Label("Follow-up needed" + dateText, systemImage: "arrow.uturn.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.heroCardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.heroCardRadius, style: .continuous)
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
