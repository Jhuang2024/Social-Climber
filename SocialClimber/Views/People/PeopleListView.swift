import SwiftUI
import SwiftData

struct PeopleListView: View {
    @Query(sort: \Person.name) private var people: [Person]

    @State private var searchText = ""
    @State private var filterCategory: PersonCategory?
    @State private var filterStatus: RelationshipStatus?
    @State private var sortOption: SortOption = .name
    @State private var showAddPerson = false
    @State private var showArchived = false

    enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case lastContacted = "Last Contacted"
        case closeness = "Closeness"
        case priority = "Priority"
        var id: String { rawValue }
    }

    private var filtered: [Person] {
        var result = people.filter { showArchived || !$0.isArchived }
        if let filterCategory {
            result = result.filter { $0.category == filterCategory }
        }
        if let filterStatus {
            result = result.filter { $0.status == filterStatus }
        }
        if !searchText.isEmpty {
            let term = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(term)
                    || $0.nickname.lowercased().contains(term)
                    || $0.relationshipToMe.lowercased().contains(term)
                    || $0.tags.contains { $0.lowercased().contains(term) }
            }
        }
        switch sortOption {
        case .name:
            break
        case .lastContacted:
            result.sort { ($0.lastContactedAt ?? .distantPast) > ($1.lastContactedAt ?? .distantPast) }
        case .closeness:
            result.sort { $0.closeness > $1.closeness }
        case .priority:
            result.sort { $0.priority > $1.priority }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    EmptyStateView(
                        icon: "person.2",
                        title: "No people yet",
                        message: "Start by adding someone you want to stay close to.",
                        actionTitle: "Add Person"
                    ) { showAddPerson = true }
                } else {
                    List {
                        ForEach(filtered) { person in
                            NavigationLink {
                                PersonProfileView(person: person)
                            } label: {
                                PersonRowView(person: person)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Name, relationship, tag…")
                    .overlay {
                        if filtered.isEmpty {
                            EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Try a different search or filter.")
                        }
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddPerson = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddPerson) { PersonEditView() }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            Menu("Category") {
                Button("All") { filterCategory = nil }
                ForEach(PersonCategory.allCases) { category in
                    Button {
                        filterCategory = category
                    } label: {
                        Label(category.label, systemImage: filterCategory == category ? "checkmark" : category.icon)
                    }
                }
            }
            Menu("Status") {
                Button("All") { filterStatus = nil }
                ForEach(RelationshipStatus.allCases) { status in
                    Button {
                        filterStatus = status
                    } label: {
                        Label(status.label, systemImage: filterStatus == status ? "checkmark" : status.icon)
                    }
                }
            }
            Toggle("Show archived", isOn: $showArchived)
        } label: {
            Image(systemName: (filterCategory != nil || filterStatus != nil) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

#Preview {
    PeopleListView()
        .modelContainer(PreviewData.container)
}
