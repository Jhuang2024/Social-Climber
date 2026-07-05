import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @Query private var reminders: [Reminder]

    private var dueCount: Int {
        reminders.filter { !$0.completed && $0.dueDate.daysFromNow <= 0 }.count
    }

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            PeopleListView()
                .tabItem { Label("People", systemImage: "person.2.fill") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            UpcomingView()
                .tabItem { Label("Upcoming", systemImage: "calendar") }
                .badge(dueCount)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
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
