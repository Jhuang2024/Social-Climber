import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @Query private var reminders: [Reminder]

    private enum Tab: Hashable { case home, people, search, upcoming, settings }

    @State private var selection: Tab = .home
    /// Bumping a tab's id rebuilds that tab's view, which resets its
    /// NavigationStack back to the root screen. We bump it whenever the user
    /// taps the tab they're already on.
    @State private var resetIDs: [Tab: UUID] = [
        .home: UUID(), .people: UUID(), .search: UUID(), .upcoming: UUID(), .settings: UUID(),
    ]

    private var dueCount: Int {
        reminders.filter { !$0.completed && $0.dueDate.daysFromNow <= 0 }.count
    }

    /// A selection binding that detects re-taps on the active tab and resets it.
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    resetIDs[newValue] = UUID()
                }
                selection = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            DashboardView()
                .id(resetIDs[.home])
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)
            PeopleListView()
                .id(resetIDs[.people])
                .tabItem { Label("People", systemImage: "person.2.fill") }
                .tag(Tab.people)
            SearchView()
                .id(resetIDs[.search])
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            UpcomingView()
                .id(resetIDs[.upcoming])
                .tabItem { Label("Upcoming", systemImage: "calendar") }
                .badge(dueCount)
                .tag(Tab.upcoming)
            SettingsView()
                .id(resetIDs[.settings])
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(.primary)
        .task {
            DemoDataCleanupService.removeBundledDemoContactsIfNeeded(context: context)
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
