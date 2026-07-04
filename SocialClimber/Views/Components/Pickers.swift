import SwiftUI
import SwiftData

/// 1–5 dot rating used for closeness, priority, and interaction quality.
struct DotRatingPicker: View {
    let label: String
    @Binding var value: Int
    var color: Color = .accentColor

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { i in
                    Circle()
                        .fill(i <= value ? color : Color(.systemFill))
                        .frame(width: 18, height: 18)
                        .onTapGesture { value = i }
                }
            }
        }
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
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            HStack {
                TextField("Add \(label.lowercased())", text: $newItem)
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
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }
}
