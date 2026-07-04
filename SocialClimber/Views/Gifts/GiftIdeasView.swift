import SwiftUI
import SwiftData

struct GiftIdeasView: View {
    @Query(sort: \GiftIdea.createdAt, order: .reverse) private var gifts: [GiftIdea]
    @Environment(\.modelContext) private var context

    @State private var filter: GiftStatus?
    @State private var showAdd = false

    private var filtered: [GiftIdea] {
        guard let filter else { return gifts }
        return gifts.filter { $0.status == filter }
    }

    /// Grouped by person name for scannability.
    private var grouped: [(String, [GiftIdea])] {
        Dictionary(grouping: filtered) { $0.person?.displayName ?? "General" }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(nil, label: "All")
                        ForEach(GiftStatus.allCases) { status in
                            filterChip(status, label: status.label)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if filtered.isEmpty {
                Section {
                    EmptyStateView(icon: "gift", title: "No gift ideas", message: "Gift ideas you add — or that AI extracts from notes — show up here.", actionTitle: "Add Gift Idea") { showAdd = true }
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(grouped, id: \.0) { name, items in
                    Section(name) {
                        ForEach(items) { gift in
                            GiftIdeaRowView(gift: gift, showPerson: false)
                        }
                        .onDelete { offsets in
                            offsets.map { items[$0] }.forEach { context.delete($0) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Gift Ideas")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { GiftIdeaEditSheet() }
    }

    private func filterChip(_ status: GiftStatus?, label: String) -> some View {
        Button {
            filter = status
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    filter == status ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                    in: Capsule()
                )
                .foregroundStyle(filter == status ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack { GiftIdeasView() }
        .modelContainer(PreviewData.container)
}
