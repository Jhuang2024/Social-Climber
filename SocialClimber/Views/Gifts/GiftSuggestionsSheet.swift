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
    /// Set when the shown suggestions are the local fallback rather than
    /// AI-generated — informational only, never blocks the list. `GiftIdeaEngine.suggestions`
    /// always returns *something* usable, so there's no separate error state.
    @State private var degradedNotice: String?

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
                } else if suggestions.isEmpty {
                    EmptyStateView(
                        icon: "gift",
                        title: "No ideas yet",
                        message: degradedNotice ?? "Log interests, notes, or interactions for \(person.firstName) so Social Climber has something to work with.",
                        actionTitle: "Try Again"
                    ) {
                        Task { await load() }
                    }
                } else {
                    List {
                        if let degradedNotice {
                            Section {
                                Label(degradedNotice, systemImage: "wifi.slash")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
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
        .task {
            // Seed from what's already a real gift idea for this person —
            // otherwise a suggestion added in an earlier session would show
            // its "+" re-enabled on reopen (reading from cache resets this
            // view's local `addedTitles`) and tapping it would create a
            // duplicate GiftIdea.
            addedTitles = Set(person.giftIdeas.map(\.title))
            // Show cached ideas instantly and only call the AI provider again
            // when the user explicitly taps refresh — opening this sheet
            // should never silently re-trigger an API call.
            let cached = person.cachedGiftSuggestions
            if !cached.isEmpty {
                suggestions = cached
            } else {
                await load()
            }
        }
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
        degradedNotice = nil
        let outcome = await GiftIdeaEngine.suggestions(for: person)
        suggestions = outcome.suggestions
        person.cachedGiftSuggestions = outcome.suggestions
        degradedNotice = outcome.notice
        isLoading = false
    }
}

#Preview {
    GiftSuggestionsSheet(person: PreviewData.samplePerson)
        .modelContainer(PreviewData.container)
}
