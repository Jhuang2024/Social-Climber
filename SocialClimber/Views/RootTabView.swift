import SwiftUI
import SwiftData

struct RootTabView: View {
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
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
