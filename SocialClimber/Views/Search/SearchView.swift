import SwiftUI
import SwiftData

struct SearchView: View {
    @Query private var people: [Person]
    @Query private var interactions: [Interaction]
    @Query private var gifts: [GiftIdea]
    @Query private var dates: [ImportantDate]

    @State private var query = ""

    private var results: SearchService.Results {
        SearchService.search(query, people: people, interactions: interactions, gifts: gifts, dates: dates)
    }

    private let suggestions = [
        "who likes F1?",
        "who did I talk to about internships?",
        "birthdays in November",
        "climbing",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    searchHeader
                    SearchBar(text: $query, placeholder: "People, notes, interests, gifts…")

                    if query.trimmingCharacters(in: .whitespaces).count < 2 {
                        suggestionsView
                    } else if results.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "Nothing found", message: "Try different words — search covers names, relationships, notes, interests, gifts, and interactions.")
                    } else {
                        resultsView
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .socialClimberPageBackground()
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Search")
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Find the thread")
                .font(.title3.weight(.bold))
            Text("Search names, context, interests, dates, and the small details that make follow-ups land.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    query = suggestion
                } label: {
                    HStack {
                        Image(systemName: "sparkle.magnifyingglass")
                            .foregroundStyle(Color.accentColor)
                        Text(suggestion)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(12)
                    .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var resultsView: some View {
        if !results.people.isEmpty {
            FormSectionCard("People", icon: "person.2") {
                ForEach(results.people) { hit in
                    NavigationLink {
                        PersonProfileView(person: hit.person)
                    } label: {
                        HStack {
                            PersonAvatarView(person: hit.person, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.person.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(hit.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
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
        if !results.dates.isEmpty {
            FormSectionCard("Dates", icon: "calendar") {
                ForEach(results.dates) { hit in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title).font(.body)
                            if let person = hit.person {
                                Text(person.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(hit.date.formatted(.dateTime.month(.wide).day()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !results.interactions.isEmpty {
            FormSectionCard("Interactions", icon: "bubble.left.and.bubble.right") {
                ForEach(results.interactions) { hit in
                    NavigationLink {
                        InteractionDetailView(interaction: hit.interaction)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            TimelineRowView(interaction: hit.interaction)
                            if !hit.reason.isEmpty || !hit.interaction.note.isEmpty {
                                Text(contextLine(primary: hit.reason, fallback: hit.interaction.note))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.leading, 44)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !results.gifts.isEmpty {
            FormSectionCard("Gift Ideas", icon: "gift") {
                ForEach(results.gifts) { hit in
                    VStack(alignment: .leading, spacing: 4) {
                        GiftIdeaRowView(gift: hit.gift)
                        if !hit.gift.notes.isEmpty || !hit.gift.occasion.isEmpty {
                            Text(contextLine(primary: hit.gift.occasion, fallback: hit.gift.notes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func contextLine(primary: String, fallback: String) -> String {
        let primary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty { return primary }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    SearchView()
        .modelContainer(PreviewData.container)
}
