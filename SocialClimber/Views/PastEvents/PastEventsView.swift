import SwiftUI
import SwiftData

/// "What's happened": a chronological record of the real events Social
/// Climber picked up from the conversations you captured or imported: to
/// you, and to the people you track.
///
/// This is deliberately not a feed of everything that was said. Interactions
/// already cover "we talked", and Learned Automatically covers durable
/// traits. Only completed changes of state land here (see `LifeEvent`), so
/// the page stays short enough to actually read.
struct PastEventsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LifeEvent.date, order: .reverse) private var allEvents: [LifeEvent]

    /// Limits the page to one person when pushed from their profile.
    var person: Person?

    @State private var scope: Scope = .everyone
    @State private var kindFilter: LifeEventKind?

    enum Scope: String, CaseIterable, Identifiable {
        case everyone, me, others
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyone: "Everyone"
            case .me: "You"
            case .others: "People"
            }
        }
    }

    private var scopedEvents: [LifeEvent] {
        allEvents.filter { event in
            guard !event.isDismissed else { return false }
            if let person {
                return event.person?.persistentModelID == person.persistentModelID
            }
            switch scope {
            case .everyone: return true
            case .me: return event.aboutMe
            case .others: return !event.aboutMe
            }
        }
    }

    private var filteredEvents: [LifeEvent] {
        guard let kindFilter else { return scopedEvents }
        return scopedEvents.filter { $0.kind == kindFilter }
    }

    /// The kinds actually present, so the filter row never offers a chip
    /// that would empty the list.
    private var availableKinds: [LifeEventKind] {
        let present = Set(scopedEvents.map(\.kind))
        return LifeEventKind.allCases.filter { present.contains($0) }
    }

    /// Grouped by month, newest first: enough structure to scan a year of
    /// history without a dense date on every row.
    private var months: [(label: String, events: [LifeEvent])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [LifeEvent]] = [:]
        for event in filteredEvents {
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: event.date)) ?? event.date
            if buckets[start] == nil { order.append(start) }
            buckets[start, default: []].append(event)
        }
        return order.map { start in
            (label: start.formatted(.dateTime.month(.wide).year()), events: buckets[start] ?? [])
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SCTheme.pageSpacing) {
                if allEvents.contains(where: { !$0.isDismissed }) {
                    if person == nil { scopePicker }
                    if availableKinds.count > 1 { kindChips }
                }

                if filteredEvents.isEmpty {
                    emptyState
                } else {
                    ForEach(months, id: \.label) { month in
                        FormSectionCard(month.label, icon: "calendar") {
                            VStack(spacing: 14) {
                                ForEach(month.events, id: \.persistentModelID) { event in
                                    row(event)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle(person == nil ? "Past Events" : "\(person?.firstName ?? "")'s Events")
        .navigationBarTitleDisplayMode(.large)
    }

    private func row(_ event: LifeEvent) -> some View {
        PastEventRowView(event: event, showSubject: person == nil)
            .contextMenu {
                Button(role: .destructive) {
                    // Dismissed rather than deleted, so reprocessing the
                    // source conversation can't bring it back.
                    event.isDismissed = true
                    event.isUserTouched = true
                } label: {
                    Label("Remove from Past Events", systemImage: "eye.slash")
                }
            }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(Scope.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: scope) { kindFilter = nil }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", color: SCTheme.accent, isSelected: kindFilter == nil) {
                    kindFilter = nil
                }
                ForEach(availableKinds) { kind in
                    chip(label: kind.label, color: kind.color, isSelected: kindFilter == kind) {
                        kindFilter = kindFilter == kind ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(label: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? .white : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.14)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "clock.badge.checkmark",
            title: kindFilter == nil ? "Nothing recorded yet" : "Nothing of that kind",
            message: kindFilter == nil
                ? "When a conversation you capture or import says something actually happened (a school decision, a new job, a move, a breakup), it lands here. Everyday chat doesn't."
                : "No events in this category yet."
        )
        .padding(.top, 40)
    }
}

#Preview {
    NavigationStack { PastEventsView() }
        .modelContainer(PreviewData.container)
}
