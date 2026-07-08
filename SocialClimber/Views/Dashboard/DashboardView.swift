import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var allPeople: [Person]
    @Query(sort: \Interaction.date, order: .reverse) private var interactions: [Interaction]
    @Query private var reminders: [Reminder]
    @Query private var giftIdeas: [GiftIdea]
    @Query private var importantDates: [ImportantDate]
    @Query(sort: \Event.date, order: .reverse) private var events: [Event]

    @AppStorage("locationEnabled") private var locationEnabled = false

    @State private var showAddPerson = false
    @State private var showAddInteraction = false
    @State private var showImport = false
    @State private var showAddEvent = false
    @State private var showVoiceCapture = false
    @State private var showContactPicker = false
    @State private var message: String?
    @State private var nearbyCity: String?
    @State private var isLoadingNearby = false
    /// Locked In Fit's readiness context, refreshed once per appearance
    /// (see `refreshCrossAppContext`). `nil` whenever the bridge is
    /// unavailable, the snapshot is missing/corrupted, or stale; Social
    /// Climber then behaves exactly as it does without the integration.
    @State private var readiness: SocialReadinessMode?

    private var people: [Person] { allPeople.filter { !$0.isArchived } }

    /// True once Locked In Fit signals low energy, poor recovery, bad
    /// sleep, or a heavy health-checklist day. Never hides social tasks,
    /// just trims how many casual/low-priority ones surface today.
    private var isReadinessReduced: Bool { readiness?.isReduced == true }

    // MARK: Derived data

    private var strategy: GlobalStrategy { StrategyEngine.global(people: people) }

    /// `strategy.nextMoves`, narrowed to only high-urgency suggestions when
    /// readiness is reduced, so a low-recovery day surfaces overdue
    /// follow-ups and birthdays but skips casual nudges.
    private var visibleNextMoves: [Suggestion] {
        guard isReadinessReduced else { return strategy.nextMoves }
        return strategy.nextMoves.filter { $0.weight >= 70 }
    }

    private var interactionsThisWeek: Int {
        interactions.filter { $0.date.daysAgo <= 7 }.count
    }

    private var followUpsDueCount: Int {
        reminders.filter { !$0.completed && $0.dueDate.daysFromNow <= 0 }.count
    }

    private var overdueReminders: [Reminder] {
        reminders.filter { $0.isOverdue }.sorted { $0.dueDate < $1.dueDate }
    }

    private var upcomingFollowUps: [Reminder] {
        reminders.filter { !$0.completed && $0.type == .followUp && $0.dueDate.daysFromNow >= 0 && $0.dueDate.daysFromNow <= 7 }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private var strongest: Person? {
        people.max { RelationshipScore.compute(for: $0).total < RelationshipScore.compute(for: $1).total }
    }

    private var coldestHighPriority: Person? {
        people.filter { $0.priority >= 4 }
            .min { RelationshipScore.compute(for: $0).total < RelationshipScore.compute(for: $1).total }
    }

    private var eventsNeedingLog: [Event] { events.filter(\.needsLogging) }
    private var upcomingEvents: [Event] {
        events.filter { $0.isUpcoming }.sorted { $0.date < $1.date }
    }

    private var nearbyPeople: [Person] {
        guard let nearbyCity, !nearbyCity.isEmpty else { return [] }
        return people.filter { person in
            let location = person.location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !location.isEmpty else { return false }
            return location.localizedCaseInsensitiveContains(nearbyCity)
                || nearbyCity.localizedCaseInsensitiveContains(location)
        }
    }

    private var checkInsDue: [Person] {
        people.filter { $0.status == .checkInSoon }.sorted { $0.priority > $1.priority }
    }

    private var quietPeople: [Person] {
        // Same ranking Strategy's "Reconnect" bucket uses, so the two
        // screens never disagree about who's most urgently going cold.
        people.filter { $0.status == .goingQuiet || $0.status == .dormant }
            .sorted { RelationshipScore.compute(for: $0).total < RelationshipScore.compute(for: $1).total }
    }

    private var upcomingBirthdays: [(Person, Date)] {
        people.compactMap { person in
            guard let next = person.nextBirthday, next.daysFromNow <= 30 else { return nil }
            return (person, next)
        }
        .sorted { $0.1 < $1.1 }
    }

    private var upcomingPlans: [Reminder] {
        reminders.filter { !$0.completed && $0.type == .hangout && $0.dueDate.daysFromNow <= 14 }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private var openGifts: [GiftIdea] {
        giftIdeas.filter { $0.status == .idea || $0.status == .planned }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    brandHeader
                    if people.isEmpty {
                        emptyDashboard
                    } else {
                        statsStrip
                        if let readiness { readinessCard(readiness) }
                        quickActions
                        if !visibleNextMoves.isEmpty { prioritiesCard }
                        if !overdueReminders.isEmpty { overdueCard }
                        if !upcomingFollowUps.isEmpty { followUpsCard }
                        if !eventsNeedingLog.isEmpty || !upcomingEvents.isEmpty { eventsCard }
                        if locationEnabled && !nearbyPeople.isEmpty { nearbyCard }
                        if !checkInsDue.isEmpty { checkInsCard }
                        if !upcomingBirthdays.isEmpty || !upcomingPlans.isEmpty { upcomingCard }
                        if !openGifts.isEmpty { giftsCard }
                        if !quietPeople.isEmpty { quietCard }
                        if !interactions.isEmpty { recentCard }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .animation(.snappy(duration: 0.3), value: people.isEmpty)
                .animation(.snappy(duration: 0.3), value: overdueReminders.count)
                .animation(.snappy(duration: 0.3), value: checkInsDue.count)
                .animation(.snappy(duration: 0.3), value: quietPeople.count)
            }
            .socialClimberPageBackground()
            .navigationTitle(greeting)
            .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
            .task { await refreshNearby() }
            .task { refreshCrossAppContext() }
            .sheet(isPresented: $showAddPerson) { PersonEditView() }
            .sheet(isPresented: $showAddInteraction) { AddInteractionView() }
            .sheet(isPresented: $showImport) { AddInteractionView(initialSource: .paste) }
            .sheet(isPresented: $showAddEvent) { EventEditView() }
            .sheet(isPresented: $showVoiceCapture) { VoiceCaptureView() }
            .sheet(isPresented: $showContactPicker) {
                ContactPickerView { contacts in
                    guard !contacts.isEmpty else { return }
                    let people = contacts.map(ContactsImporter.person(from:))
                    people.forEach { context.insert($0) }
                    Haptics.success()
                    if let only = people.first, people.count == 1 {
                        message = "Imported \(only.displayName)."
                    } else {
                        message = "Imported \(people.count) contacts."
                    }
                }
            }
            .alert("Social Climber", isPresented: .init(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case ..<12: return "Good Morning"
        case ..<17: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    private func refreshNearby() async {
        guard locationEnabled else { nearbyCity = nil; return }
        isLoadingNearby = true
        nearbyCity = await LocationService.shared.currentCity()
        isLoadingNearby = false
    }

    /// Publishes Social Climber's own public context snapshot for Locked In
    /// Fit and reads back its readiness context, if any. Both directions
    /// are best-effort and silent: no App Group, no file, a stale
    /// timestamp, or corrupted JSON all just mean `readiness` stays `nil`.
    private func refreshCrossAppContext() {
        CrossAppIntegrationManager.publish(reminders: reminders, events: events)
        readiness = CrossAppIntegrationManager.readinessMode()
    }

    // MARK: Sections

    private var brandHeader: some View {
        HStack(spacing: 12) {
            BrandLogoView(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("Social Climber")
                    .font(.headline.weight(.semibold))
                Text("Local-first relationship memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        .overlay(alignment: .trailing) {
            Image(systemName: "lock.shield.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
                .padding(.trailing, 14)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyDashboard: some View {
        VStack(spacing: 18) {
            BrandLogoView(size: 58)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text("Start with one real relationship")
                    .font(.title3.weight(.semibold))
                Text("Social Climber is ready when you add a person, log a memory, import a message, or record a live conversation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                EmptyActionButton(icon: "person.badge.plus", title: "Add person", color: .blue) { showAddPerson = true }
                EmptyActionButton(icon: "plus.bubble.fill", title: "Add interaction", color: .green) { showAddInteraction = true }
                EmptyActionButton(icon: "square.and.arrow.down", title: "Import message", color: .pink) { showImport = true }
                EmptyActionButton(icon: "person.crop.circle.badge.plus", title: "Import contact", color: .orange) { showContactPicker = true }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
        .cardShadow()
    }

    private var statsStrip: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatCard(title: "People", value: "\(people.count)", icon: "person.2.fill", color: .blue)
            StatCard(title: "This Week", value: "\(interactionsThisWeek)", icon: "bubble.left.and.bubble.right.fill", color: .green)
            StatCard(title: "Follow-ups Due", value: "\(followUpsDueCount)", icon: "bell.badge.fill", color: .orange)
            if let strongest {
                NavigationLink(value: strongest) {
                    StatCard(title: "Strongest", value: strongest.firstName, icon: "flame.fill", color: .pink)
                }
                .buttonStyle(.pressable)
            }
            if let coldestHighPriority {
                NavigationLink(value: coldestHighPriority) {
                    StatCard(title: "Coldest Priority", value: coldestHighPriority.firstName, icon: "snowflake", color: .teal)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            Button { showAddInteraction = true } label: {
                QuickActionLabel(icon: "plus.bubble.fill", label: "Log", color: .green)
            }.buttonStyle(.pressable)
            Button { showImport = true } label: {
                QuickActionLabel(icon: "square.and.arrow.down", label: "Import", color: .pink)
            }.buttonStyle(.pressable)
            Button { showAddPerson = true } label: {
                QuickActionLabel(icon: "person.badge.plus", label: "Add Contact", color: .blue)
            }.buttonStyle(.pressable)
            Button { showContactPicker = true } label: {
                QuickActionLabel(icon: "person.crop.circle.badge.plus", label: "Import Contacts", color: .teal)
            }.buttonStyle(.pressable)
            Button { showAddEvent = true } label: {
                QuickActionLabel(icon: "calendar.badge.plus", label: "Event", color: .orange)
            }.buttonStyle(.pressable)
            NavigationLink { StrategyView() } label: {
                QuickActionLabel(icon: "wand.and.stars", label: "Strategy", color: .purple)
            }.buttonStyle(.pressable)
            Button { showVoiceCapture = true } label: {
                QuickActionLabel(icon: "waveform", label: "Voice", color: .indigo)
            }.buttonStyle(.pressable)
        }
    }

    /// A one-line, subtly-marked note surfacing Locked In Fit's imported
    /// readiness context. Never editable here: Social Climber only ever
    /// displays it, never writes back to Locked In Fit's data.
    private func readinessCard(_ readiness: SocialReadinessMode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: readiness.isReduced ? "moon.zzz.fill" : "bolt.heart.fill")
                .font(.subheadline)
                .foregroundStyle(readiness.isReduced ? .orange : .secondary)
            Text(readiness.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("Locked In Fit")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
    }

    private var prioritiesCard: some View {
        FormSectionCard("Today's Priorities", icon: "flag.fill") {
            ForEach(visibleNextMoves.prefix(isReadinessReduced ? 2 : 4)) { suggestion in
                SuggestionRow(suggestion: suggestion)
            }
            NavigationLink { StrategyView() } label: {
                Label("View full strategy", systemImage: "arrow.right")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var overdueCard: some View {
        FormSectionCard("Overdue Follow-ups", icon: "exclamationmark.arrow.circlepath") {
            ForEach(overdueReminders.prefix(4)) { reminder in
                ReminderRowView(reminder: reminder)
            }
        }
    }

    private var followUpsCard: some View {
        FormSectionCard("Upcoming Follow-ups", icon: "arrow.uturn.right.circle.fill") {
            ForEach(upcomingFollowUps.prefix(4)) { reminder in
                ReminderRowView(reminder: reminder)
            }
        }
    }

    private var eventsCard: some View {
        FormSectionCard("Events", icon: "party.popper.fill") {
            ForEach(eventsNeedingLog.prefix(3), id: \.persistentModelID) { event in
                eventRow(event, needsLog: true)
            }
            ForEach(upcomingEvents.prefix(3), id: \.persistentModelID) { event in
                eventRow(event, needsLog: false)
            }
            NavigationLink { EventsListView() } label: {
                Label("All events", systemImage: "arrow.right")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private func eventRow(_ event: Event, needsLog: Bool) -> some View {
        NavigationLink { EventDetailView(event: event) } label: {
            HStack {
                Image(systemName: needsLog ? "square.and.pencil" : "calendar")
                    .font(.subheadline)
                    .foregroundStyle(needsLog ? .orange : SCTheme.accent)
                    .frame(width: 30, height: 30)
                    .background((needsLog ? Color.orange : SCTheme.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.name.isEmpty ? "Untitled event" : event.name)
                        .font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(needsLog ? "Tap to log interactions" : event.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption).foregroundStyle(needsLog ? .orange : .secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var nearbyCard: some View {
        FormSectionCard("In \(nearbyCity ?? "Your City")", icon: "location.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(nearbyPeople.prefix(8)) { person in
                        NavigationLink(value: person) {
                            PersonMiniCard(person: person)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            Button {
                Task { await refreshNearby() }
            } label: {
                Label(isLoadingNearby ? "Refreshing…" : "Refresh location", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(isLoadingNearby)
        }
    }

    private var checkInsCard: some View {
        FormSectionCard("Check In Soon", icon: "bubble.left.and.bubble.right.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(checkInsDue.prefix(isReadinessReduced ? 3 : 8)) { person in
                        NavigationLink(value: person) {
                            PersonMiniCard(person: person)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    /// Birthdays and tracked plans both used to get their own card, showing
    /// largely the same kind of "something's coming up" information as the
    /// dedicated Upcoming tab. One combined preview here, linking to that
    /// full merged feed, replaces two overlapping cards with one.
    private var upcomingCard: some View {
        FormSectionCard("Upcoming", icon: "calendar.badge.clock") {
            ForEach(upcomingBirthdays.prefix(3), id: \.0.persistentModelID) { person, date in
                NavigationLink(value: person) {
                    HStack {
                        PersonAvatarView(person: person, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("Birthday · \(date.formatted(.dateTime.month(.wide).day()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let days = date.daysFromNow
                        Text(days == 0 ? "Today 🎂" : "in \(days)d")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(days <= 7 ? .pink : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(upcomingPlans.prefix(3)) { reminder in
                ReminderRowView(reminder: reminder)
            }
            NavigationLink { UpcomingView() } label: {
                Label("View all upcoming", systemImage: "arrow.right")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var giftsCard: some View {
        FormSectionCard("Gift Ideas", icon: "gift.fill") {
            ForEach(openGifts.prefix(3)) { gift in
                GiftIdeaRowView(gift: gift)
            }
            NavigationLink("All gift ideas (\(openGifts.count))") { GiftIdeasView() }
                .font(.subheadline.weight(.medium))
        }
    }

    private var quietCard: some View {
        FormSectionCard("People Going Cold", icon: "moon.zzz.fill") {
            ForEach(quietPeople.prefix(isReadinessReduced ? 2 : 4)) { person in
                NavigationLink(value: person) {
                    HStack {
                        PersonAvatarView(person: person, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if let days = RelationshipHealth.daysSinceContact(for: person) {
                                Text("Last contact \(days) days ago")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        RelationshipStatusBadge(status: person.status)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentCard: some View {
        FormSectionCard("Recent Interactions", icon: "clock.arrow.circlepath") {
            ForEach(interactions.prefix(5)) { interaction in
                NavigationLink { InteractionDetailView(interaction: interaction) } label: {
                    TimelineRowView(interaction: interaction)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct QuickActionLabel: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous)
                .strokeBorder(color.opacity(0.16))
        }
        .foregroundStyle(color)
    }
}

private struct EmptyActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
            .foregroundStyle(color)
        }
        .buttonStyle(.pressable)
    }
}

private struct PersonMiniCard: View {
    let person: Person

    var body: some View {
        VStack(spacing: 8) {
            PersonAvatarView(person: person, size: 52)
            Text(person.firstName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            if let days = RelationshipHealth.daysSinceContact(for: person) {
                Text("\(days)d ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84)
        .padding(.vertical, 10)
        .background(SCTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: SCTheme.controlRadius, style: .continuous))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SCTheme.cardBackground, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05))
        }
    }
}

#Preview {
    DashboardView()
        .modelContainer(PreviewData.container)
}
