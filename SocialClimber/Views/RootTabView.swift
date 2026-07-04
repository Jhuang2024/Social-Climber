import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            DashboardView()
                .tint(Color.accentColor)
                .tabItem { Label("Home", systemImage: "house.fill") }
            PeopleListView()
                .tint(Color.accentColor)
                .tabItem { Label("People", systemImage: "person.2.fill") }
            SearchView()
                .tint(Color.accentColor)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            UpcomingView()
                .tint(Color.accentColor)
                .tabItem { Label("Upcoming", systemImage: "calendar") }
            SettingsView()
                .tint(Color.accentColor)
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
