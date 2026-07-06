import SwiftUI
import SwiftData

/// The global Strategy screen — a rule-based command center for who to reach
/// out to next. Pushed inside a NavigationStack that provides a
/// `navigationDestination(for: Person.self)` (the Dashboard's).
struct StrategyView: View {
    @Query(sort: \Person.name) private var people: [Person]

    private var strategy: GlobalStrategy {
        StrategyEngine.global(people: people)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if strategy.isEmpty {
                    EmptyStateView(
                        icon: "sparkles",
                        title: "You're all caught up",
                        message: "No urgent moves right now. Log interactions and add people, and suggestions will appear here."
                    )
                } else {
                    if !strategy.nextMoves.isEmpty {
                        FormSectionCard("Suggested Next Moves", icon: "wand.and.stars") {
                            ForEach(strategy.nextMoves.prefix(6)) { suggestion in
                                SuggestionRow(suggestion: suggestion)
                            }
                        }
                    }
                    peopleCard("People to Reconnect With", icon: "arrow.triangle.2.circlepath",
                               people: strategy.reconnect, subtitleFor: coldSubtitle)
                    peopleCard("High-Priority Going Cold", icon: "star.slash",
                               people: strategy.highPriorityCold, subtitleFor: coldSubtitle)
                    peopleCard("Overdue Follow-ups", icon: "exclamationmark.arrow.circlepath",
                               people: strategy.overdueFollowUps, subtitleFor: overdueSubtitle)
                    peopleCard("Recent Positive Moments", icon: "hand.thumbsup",
                               people: strategy.recentPositive, subtitleFor: positiveSubtitle)
                }
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Strategy")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func peopleCard(_ title: String, icon: String, people: [Person], subtitleFor: @escaping (Person) -> String) -> some View {
        if !people.isEmpty {
            FormSectionCard(title, icon: icon) {
                ForEach(people.prefix(6), id: \.persistentModelID) { person in
                    NavigationLink(value: person) {
                        HStack(spacing: 12) {
                            PersonAvatarView(person: person, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(subtitleFor(person))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ScoreRing(score: RelationshipScore.compute(for: person).total,
                                      color: RelationshipScore.compute(for: person).band.color, size: 38)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func coldSubtitle(_ person: Person) -> String {
        if let days = RelationshipHealth.daysSinceContact(for: person) {
            return "Last contact \(days) days ago"
        }
        return "No contact logged yet"
    }

    private func overdueSubtitle(_ person: Person) -> String {
        let count = person.reminders.filter(\.isOverdue).count
        return "\(count) overdue reminder\(count == 1 ? "" : "s")"
    }

    private func positiveSubtitle(_ person: Person) -> String {
        guard let recent = person.sortedInteractions.first else { return "" }
        return "\(recent.sentiment.label) · \(recent.date.relativeLabel)"
    }
}

/// A single actionable suggestion row, optionally linking to its person.
struct SuggestionRow: View {
    let suggestion: Suggestion
    var linksToPerson: Bool = true

    var body: some View {
        if linksToPerson, let person = suggestion.person {
            NavigationLink(value: person) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(suggestion.color)
                .frame(width: 32, height: 32)
                .background(suggestion.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(suggestion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let person = suggestion.person {
                        Text(person.firstName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        StrategyView()
            .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
    }
    .modelContainer(PreviewData.container)
}
