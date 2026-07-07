import SwiftUI
import SwiftData

/// 1–5 dot rating used for closeness, priority, and interaction quality.
struct DotRatingPicker: View {
    let label: String
    @Binding var value: Int
    var color: Color = SCTheme.accent

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { i in
                    Button {
                        withAnimation(.snappy(duration: 0.16)) { value = i }
                    } label: {
                        Circle()
                            .fill(i <= value ? color : Color(.systemFill))
                            .frame(width: 18, height: 18)
                            .overlay {
                                Circle().strokeBorder(color.opacity(i <= value ? 0 : 0.20))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: value)
    }
}

/// Four-level sentiment selector (bad / neutral / good / great) shown as a
/// row of tappable chips. Backed by the same 1–5 quality scale as before.
struct SentimentPicker: View {
    @Binding var sentiment: Sentiment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How did it go?")
                .font(.subheadline)
            HStack(spacing: 8) {
                ForEach(Sentiment.allCases) { option in
                    Button {
                        withAnimation(.snappy(duration: 0.16)) { sentiment = option }
                    } label: {
                        VStack(spacing: 4) {
                            Text(option.emoji)
                                .font(.title3)
                            Text(option.label)
                                .font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            (sentiment == option ? option.color.opacity(0.20) : Color(.tertiarySystemFill)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(sentiment == option ? option.color : .clear, lineWidth: 1.5)
                        }
                        .foregroundStyle(sentiment == option ? option.color : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: sentiment)
    }
}

/// Comma-separated editor for string lists (interests, tags, ...).
struct TagListEditor: View {
    let label: String
    @Binding var items: [String]
    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item).font(.subheadline)
                            Button {
                                items.removeAll { $0 == item }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SCTheme.accent.opacity(0.12), in: Capsule())
                        .foregroundStyle(SCTheme.accent)
                    }
                }
            }
            HStack {
                TextField("Add \(label.lowercased())", text: $newItem)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        for part in trimmed.components(separatedBy: ",") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if !item.isEmpty, !items.contains(item) { items.append(item) }
        }
        newItem = ""
    }
}

/// Multi-select list of people with avatars and checkmarks.
struct PersonMultiPicker: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Binding var selected: [Person]

    var body: some View {
        List {
            ForEach(people.filter { !$0.isArchived }) { person in
                Button {
                    if let index = selected.firstIndex(where: { $0 === person }) {
                        selected.remove(at: index)
                    } else {
                        selected.append(person)
                    }
                } label: {
                    HStack {
                        PersonAvatarView(person: person, size: 36)
                        VStack(alignment: .leading) {
                            Text(person.displayName)
                                .foregroundStyle(.primary)
                            Text(person.relationshipToMe.isEmpty ? person.category.label : person.relationshipToMe)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.contains(where: { $0 === person }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(SCTheme.accent)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SCTheme.cardBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SCTheme.pageBackground)
        .sensoryFeedback(.selection, trigger: selected.count)
    }
}
