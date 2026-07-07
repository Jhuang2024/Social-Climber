import SwiftUI
import SwiftData

/// Presents AI-generated gift ideas for a single person, grounded in what
/// Social Climber already knows about them (interests, notes, tags, past
/// interactions). The user picks which suggestions become real gift ideas.
struct GiftSuggestionsSheet: View {
    let person: Person
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var suggestions: [GiftSuggestion] = []
    @State private var addedTitles: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Thinking of gift ideas for \(person.firstName)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Couldn't generate ideas",
                        message: errorMessage,
                        actionTitle: "Try Again"
                    ) {
                        Task { await load() }
                    }
                } else if suggestions.isEmpty {
                    EmptyStateView(
                        icon: "gift",
                        title: "No ideas yet",
                        message: "Log interests, notes, or interactions for \(person.firstName) so Social Climber has something to work with.",
                        actionTitle: "Try Again"
                    ) {
                        Task { await load() }
                    }
                } else {
                    List {
                        ForEach(suggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Gift Ideas for \(person.firstName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func suggestionRow(_ suggestion: GiftSuggestion) -> some View {
        let added = addedTitles.contains(suggestion.title)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gift.fill")
                .font(.body)
                .foregroundStyle(.purple)
                .frame(width: 32, height: 32)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.body.weight(.medium))
                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if !suggestion.occasion.isEmpty {
                        Text(suggestion.occasion).font(.caption).foregroundStyle(.secondary)
                    }
                    if !suggestion.priceRange.isEmpty {
                        Text(suggestion.priceRange).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                add(suggestion)
            } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(added ? .green : SCTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(added)
        }
        .padding(.vertical, 4)
    }

    private func add(_ suggestion: GiftSuggestion) {
        let gift = GiftIdea(
            title: suggestion.title,
            person: person,
            notes: suggestion.reason,
            priceRange: suggestion.priceRange,
            occasion: suggestion.occasion
        )
        context.insert(gift)
        addedTitles.insert(suggestion.title)
        Haptics.success()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            suggestions = try await GiftIdeaEngine.suggestions(for: person)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    GiftSuggestionsSheet(person: PreviewData.samplePerson)
        .modelContainer(PreviewData.container)
}
