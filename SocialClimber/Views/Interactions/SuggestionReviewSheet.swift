import SwiftUI

/// Shown after AI analysis finds at least one interest, gift idea,
/// reminder, important date, or personality note to suggest — lets the
/// user approve or reject each one individually before anything is
/// actually written to a person's profile. Tapping "Back" just returns to
/// the form underneath; nothing has been saved yet at this point.
struct SuggestionReviewSheet: View {
    let extraction: AIExtraction
    @Binding var options: ExtractionApplier.Options
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Review what the AI found — anything left unchecked won't be added.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                AISuggestionChecklist(extraction: extraction, options: $options)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SCTheme.pageBackground)
            .navigationTitle("Review Suggestions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                        onConfirm()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    SuggestionReviewSheet(
        extraction: AIExtraction(
            summary: "Preview summary",
            interests: ["Hiking", "Coffee"],
            giftIdeas: ["Trail mix gift box"],
            reminders: [ExtractedReminder(title: "Follow up next week", dueDate: nil)],
            personalityNotes: ["Loves the outdoors"]
        ),
        options: .constant(.allApproved(for: AIExtraction()))
    ) {}
}
