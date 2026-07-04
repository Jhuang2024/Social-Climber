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
    @State private var showVoiceCapture = false

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
            ZStack(alignment: .bottom) {
                Group {
                    if people.isEmpty {
                        EmptyStateView(
                            icon: "person.2",
                            title: "Your circle starts here",
                            message: "Add the first person worth remembering. Notes, reminders, gifts, and context will build from there.",
                            actionTitle: "Add Person"
                        ) { showAddPerson = true }
                        .padding(.horizontal)
                    } else {
                        List {
                            ForEach(filtered, id: \.persistentModelID) { person in
                                NavigationLink {
                                    PersonProfileView(person: person)
                                } label: {
                                    PersonRowView(person: person)
                                }
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                                        .fill(SCTheme.cardBackground)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                )
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .searchable(text: $searchText, prompt: "Name, relationship, tag…")
                        .overlay {
                            if filtered.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Try a different search or clear the current filter.")
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                .safeAreaPadding(.bottom, 86)

                voiceNoteBar
            }
            .background(SCTheme.pageBackground)
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
            .sheet(isPresented: $showVoiceCapture) { VoiceCaptureView() }
        }
    }

    private var voiceNoteBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showVoiceCapture = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.accentColor.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Record a conversation")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Capture a live conversation, reminder, or follow-up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.clear, Color.black.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 1)
            }
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
