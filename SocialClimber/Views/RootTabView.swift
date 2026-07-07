import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]

    private enum Tab: Hashable { case home, people, search, upcoming, settings }

    @State private var selection: Tab = .home
    /// Bumping a tab's id rebuilds that tab's view, which resets its
    /// NavigationStack back to the root screen. We bump it whenever the user
    /// taps the tab they're already on.
    @State private var resetIDs: [Tab: UUID] = [
        .home: UUID(), .people: UUID(), .search: UUID(), .upcoming: UUID(), .settings: UUID(),
    ]
    /// Text queued by the Share Extension (e.g. Messages bubbles shared from
    /// outside the app), waiting to be reviewed. Checked on launch and every
    /// time the app returns to the foreground, since the extension runs in
    /// its own process and can't hand this off any other way.
    @State private var pendingSharedImport: SharedImportEntry?

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
        // Deliberately no `.tint()` here: a tint set this high cascades to
        // every screen in every tab as the *ambient* tint, not just the tab
        // bar — it's what was turning Toggles and destructive buttons grey
        // app-wide instead of their normal green/red (see SCTheme.accent's
        // doc comment for the same lesson learned the hard way once
        // already). Let each screen's controls use their real system/brand
        // color instead.
        .task {
            DemoDataCleanupService.removeBundledDemoContactsIfNeeded(context: context)
            checkForSharedImport()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { checkForSharedImport() }
        }
        .sheet(item: $pendingSharedImport, onDismiss: checkForSharedImport) { entry in
            AddInteractionView(initialSource: .paste, initialRawText: entry.text)
        }
    }

    /// Pulls the next queued share off the inbox (if any) and presents it.
    /// Removing it up front — rather than waiting for the sheet to be saved
    /// — means cancelling out of the pre-filled form simply discards that
    /// one shared snippet instead of leaving it stuck re-appearing forever;
    /// re-sharing is one tap if that was a mistake. Called again as each
    /// sheet dismisses so multiple queued shares are worked through one at
    /// a time instead of only showing the first.
    private func checkForSharedImport() {
        guard pendingSharedImport == nil else { return }
        guard let next = SharedImportInbox.pending().first else { return }
        SharedImportInbox.remove(next.id)
        pendingSharedImport = next
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
