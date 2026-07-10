import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]
    @Query(sort: \Person.name) private var allPeople: [Person]

    private enum Tab: Hashable { case home, people, search, upcoming, settings }

    @State private var selection: Tab = .home
    /// Bumping a tab's id rebuilds that tab's view, which resets its
    /// NavigationStack back to the root screen. We bump it whenever the user
    /// taps the tab they're already on.
    @State private var resetIDs: [Tab: UUID] = [
        .home: UUID(), .people: UUID(), .search: UUID(), .upcoming: UUID(), .settings: UUID(),
    ]
    /// The single presentation point for Quick Capture, shared by Home,
    /// person profiles, App Intents, and notification actions.
    @State private var captureRouter = QuickCaptureRouter.shared
    /// "Did you reach Jimmy?", set when the app returns to the foreground
    /// within the plausible window after the user launched a call/message
    /// from a profile. Non-modal banner, never an alert.
    @State private var outboundPrompt: PendingOutboundContact?

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
        // bar; it's what was turning Toggles and destructive buttons grey
        // app-wide instead of their normal green/red (see SCTheme.accent's
        // doc comment for the same lesson learned the hard way once
        // already). Let each screen's controls use their real system/brand
        // color instead.
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay { ToastOverlay() }
        .overlay(alignment: .top) {
            if let prompt = outboundPrompt {
                outboundBanner(prompt)
            }
        }
        .sheet(item: Bindable(captureRouter).pendingRequest) { request in
            QuickCaptureView(request: request)
        }
        .task {
            DemoDataCleanupService.removeBundledDemoContactsIfNeeded(context: context)
            await CaptureProcessor.shared.handleAppActivated()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // Shared payloads become durable capture records and process
            // silently; never a modal, never "finish logging this".
            Task { await CaptureProcessor.shared.handleAppActivated() }
            checkOutboundReturn()
        }
    }

    // MARK: Outbound-contact return prompt

    private func checkOutboundReturn() {
        guard outboundPrompt == nil else { return }
        guard let pending = OutboundContactStore.currentWithinWindow() else { return }
        withAnimation(.snappy) { outboundPrompt = pending }
    }

    private func outboundBanner(_ prompt: PendingOutboundContact) -> some View {
        let firstName = prompt.personName.components(separatedBy: " ").first ?? prompt.personName
        return VStack(spacing: 10) {
            Text("Did you reach \(firstName)?")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Button {
                    resolveOutbound(prompt, logged: true)
                } label: {
                    Text("Yes")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.16), in: Capsule())
                        .foregroundStyle(.green)
                }
                Button {
                    addNoteForOutbound(prompt)
                } label: {
                    Text("Add note")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(SCTheme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(SCTheme.accent)
                }
                Button {
                    resolveOutbound(prompt, logged: false)
                } label: {
                    Text("Not this time")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// "Yes" logs a minimal neutral interaction in one tap; "Not this time"
    /// just clears the prompt. Either way the pending record is consumed so
    /// the question is asked at most once.
    private func resolveOutbound(_ prompt: PendingOutboundContact, logged: Bool) {
        OutboundContactStore.clear()
        withAnimation(.snappy) { outboundPrompt = nil }
        guard logged else { return }
        guard let person = allPeople.first(where: { $0.name == prompt.personName }) else { return }
        let interaction = Interaction(
            type: prompt.interactionType,
            date: .now,
            quality: 3,
            messageSummary: "Reached out via \(prompt.interactionType.label.lowercased())"
        )
        InteractionSaver.finalize(interaction, people: [person], context: context)
        Haptics.success()
        ToastCenter.shared.show("Logged contact with \(person.firstName)")
    }

    private func addNoteForOutbound(_ prompt: PendingOutboundContact) {
        OutboundContactStore.clear()
        withAnimation(.snappy) { outboundPrompt = nil }
        guard let person = allPeople.first(where: { $0.name == prompt.personName }) else { return }
        QuickCaptureRouter.shared.open(person: person, typeHint: prompt.interactionType)
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
