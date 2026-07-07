import SwiftUI

/// A checklist of AI-suggested items — interests, gift ideas, reminders,
/// important dates, personality notes — that the user can approve or
/// reject individually before anything is written to a person's profile.
/// Shared by every interaction-logging flow (manual notes, paste/screenshot
/// import, voice notes) so a suggestion is never silently added, or
/// silently dropped along with ones the user actually wanted, without a
/// chance to review each one on its own.
///
/// Starts fully checked (every suggestion pre-approved) — the user rejects
/// what they don't want rather than having to opt into everything, keeping
/// the common case (accept most of it) a single tap away.
struct AISuggestionChecklist: View {
    let extraction: AIExtraction
    @Binding var options: ExtractionApplier.Options

    var body: some View {
        Group {
            if !extraction.interests.isEmpty {
                checklistSection("Interests", items: extraction.interests, label: { $0 }, selection: $options.selectedInterests)
            }
            if !extraction.giftIdeas.isEmpty {
                checklistSection("Gift Ideas", items: extraction.giftIdeas, label: { $0 }, selection: $options.selectedGiftIdeas)
            }
            if !extraction.reminders.isEmpty {
                checklistSection("Reminders", items: extraction.reminders, label: \.title, selection: $options.selectedReminders)
            }
            if !extraction.importantDates.isEmpty {
                checklistSection("Important Dates", items: extraction.importantDates, label: \.display, selection: $options.selectedImportantDates)
            }
            if !extraction.personalityNotes.isEmpty {
                checklistSection("Personality Notes", items: extraction.personalityNotes, label: { $0 }, selection: $options.selectedPersonalityNotes)
            }
        }
    }

    private func checklistSection<Item: Hashable>(
        _ title: String,
        items: [Item],
        label: @escaping (Item) -> String,
        selection: Binding<Set<Item>>
    ) -> some View {
        Section {
            ForEach(items, id: \.self) { item in
                let isApproved = selection.wrappedValue.contains(item)
                Button {
                    if isApproved {
                        selection.wrappedValue.remove(item)
                    } else {
                        selection.wrappedValue.insert(item)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isApproved ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isApproved ? SCTheme.accent : .secondary)
                        Text(label(item))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(title)
        }
    }
}
