import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]
    @Query(sort: \Person.name) private var allPeople: [Person]
    @Query private var importantDates: [ImportantDate]
    @Query private var events: [Event]
    @Query private var voiceNotes: [VoiceNote]

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

    /// Deep-link bus for notification actions (open reminder/contact, review
    /// capture, log interaction).
    private let router = NotificationRouter.shared

    private var dueCount: Int {
        reminders.filter { !$0.completed && $0.dueDate.daysFromNow <= 0 }.count
    }

    /// Captures that failed processing and are still worth retrying, surfaced
    /// as the "needs review" count for notifications.
    private var pendingCaptureCount: Int {
        voiceNotes.filter { $0.processingState == .failed && ($0.failureReason?.isRetryable ?? false) }.count
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
        // bar (see SCTheme.accent's doc comment). Let each screen's controls
        // use their real system/brand color instead.
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
            reconcileNotifications()
            await processPendingCaptures()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Rewrite the cross-app snapshot and Brief feed as the app
                // leaves the foreground, so tomorrow's brief reflects this
                // session's edits even if the dashboard (the only other
                // publish site) is never revisited today. Both calls are
                // gated on the sharing toggle and fail-silent.
                CrossAppIntegrationManager.publish(reminders: reminders, events: events)
                CrossAppIntegrationManager.publishBriefFeed(context: context)
            }
            guard newPhase == .active else { return }
            // Shared payloads become durable capture records and process
            // silently; never a modal, never "finish logging this".
            Task { await CaptureProcessor.shared.handleAppActivated() }
            checkOutboundReturn()
            reconcileNotifications()
            Task { await processPendingCaptures() }
        }
        // Reconcile whenever the data that drives notifications changes, so a
        // completed/deleted/edited item updates its scheduled alerts.
        .onChange(of: reminders.count) { reconcileNotifications() }
        .onChange(of: importantDates.count) { reconcileNotifications() }
        .onChange(of: events.count) { reconcileNotifications() }
        .onChange(of: pendingCaptureCount) { reconcileNotifications() }
        // Time-zone changes: recompute all fire times against the new local
        // hours so a 9 AM reminder stays 9 AM local.
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            reconcileNotifications()
        }
        // Notification-action deep links.
        .onChange(of: router.pending) { _, destination in
            handle(destination: destination)
        }
    }

    // MARK: Notifications

    private func reconcileNotifications() {
        NotificationService.shared.reconcile(
            people: allPeople,
            reminders: reminders,
            importantDates: importantDates,
            events: events,
            pendingCaptureCount: pendingCaptureCount
        )
        try? context.save()
    }

    private func processPendingCaptures() async {
        await RecordingProcessor.shared.processPending(
            context: context,
            contactNames: allPeople.map(\.name)
        )
    }

    private func handle(destination: NotificationRouter.Destination?) {
        guard let destination else { return }
        switch destination {
        case .reminders:
            selection = .upcoming
        case .captureReview, .logInteraction:
            selection = .home
        case .contact:
            selection = .people
        }
        // Consume it so re-selecting the same destination later still fires.
        DispatchQueue.main.async { router.pending = nil }
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
