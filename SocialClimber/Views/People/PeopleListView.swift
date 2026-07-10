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
            result = result.filter { $0.matchesSearch(searchText) }
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
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.immediately)
                        .searchable(text: $searchText, prompt: "Name, interest, tag, note…")
                        .animation(.snappy(duration: 0.25), value: filtered.map(\.persistentModelID))
                        .overlay {
                            if filtered.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Try a different search or clear the current filter.")
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                .safeAreaPadding(.bottom, 128)

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
        Button {
            showVoiceCapture = true
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 58, height: 58)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record a conversation")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Capture a live conversation, reminder, or follow-up")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(SCTheme.accent.gradient, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
            .cardShadow()
        }
        .buttonStyle(.pressable)
        .padding(.horizontal)
        .padding(.bottom, 10)
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
                .tint(.green)
        } label: {
            Image(systemName: (filterCategory != nil || filterStatus != nil) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .sensoryFeedback(.selection, trigger: filterCategory)
        .sensoryFeedback(.selection, trigger: filterStatus)
        .sensoryFeedback(.selection, trigger: sortOption)
    }
}

#Preview {
    PeopleListView()
        .modelContainer(PreviewData.container)
}
