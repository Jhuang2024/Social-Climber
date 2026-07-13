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

    @Query(sort: \CapturedMemory.capturedAt, order: .reverse) private var captures: [CapturedMemory]

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

    // MARK: Capture feed slices: exception-driven, small, never an inbox.

    private var capturesNeedingContext: [CapturedMemory] {
        captures.filter { $0.status == .needsContext }
    }

    private var failedCaptures: [CapturedMemory] {
        captures.filter { $0.status == .failed }
    }

    private var recentCaptures: [CapturedMemory] {
        captures.filter { $0.status == .processed || $0.status == .queued || $0.status == .processing }
    }

    private var recentCaptureAvatars: [Person] {
        people.filter { $0.lastContactedAt != nil }
            .sorted { ($0.lastContactedAt ?? .distantPast) > ($1.lastContactedAt ?? .distantPast) }
            .prefix(4)
            .map { $0 }
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
                    captureHero
                    if people.isEmpty {
                        emptyDashboard
                    } else {
                        if !capturesNeedingContext.isEmpty { needsContextCard }
                        if !failedCaptures.isEmpty { failedCapturesCard }
                        statsStrip
                        socialHealthLink
                        if let readiness { readinessCard(readiness) }
                        secondaryActions
                        if !recentCaptures.isEmpty { recentCapturesCard }
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

    private var socialHealthLink: some View {
        NavigationLink { SocialHealthView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.pink.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Social Health")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Your whole social life, one explainable score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            BrandLogoView(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                // The masthead: set in the serif display face like a
                // publication's nameplate.
                Text("Social Climber")
                    .font(SCTheme.displayFont(19, weight: .bold))
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
                Text("Add a person, then just tell Social Climber what happened, like \"Had coffee with Jimmy…\", and it organizes the rest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                EmptyActionButton(icon: "person.badge.plus", title: "Add person", color: SCTheme.Accents.primary) { showAddPerson = true }
                EmptyActionButton(icon: "sparkles", title: "Remember something", color: SCTheme.Accents.growth) { QuickCaptureRouter.shared.open() }
                EmptyActionButton(icon: "square.and.arrow.down", title: "Import message", color: SCTheme.Accents.cool) { showImport = true }
                EmptyActionButton(icon: "person.crop.circle.badge.plus", title: "Import contact", color: SCTheme.Accents.cool) { showContactPicker = true }
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
            StatCard(title: "People", value: "\(people.count)", icon: "person.2.fill", color: SCTheme.Accents.primary)
            StatCard(title: "This Week", value: "\(interactionsThisWeek)", icon: "bubble.left.and.bubble.right.fill", color: SCTheme.Accents.growth)
            StatCard(title: "Follow-ups Due", value: "\(followUpsDueCount)", icon: "bell.badge.fill", color: SCTheme.Accents.alert)
            if let strongest {
                NavigationLink(value: strongest) {
                    StatCard(title: "Strongest", value: strongest.firstName, icon: "flame.fill", color: SCTheme.Accents.warm)
                }
                .buttonStyle(.pressable)
            }
            if let coldestHighPriority {
                NavigationLink(value: coldestHighPriority) {
                    StatCard(title: "Coldest Priority", value: coldestHighPriority.firstName, icon: "snowflake", color: SCTheme.Accents.alert)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    /// The one dominant capture surface. Tapping the body opens Quick
    /// Capture; the mic opens it already recording; the photo icon opens it
    /// ready for a screenshot. Everything else on Home is secondary.
    private var captureHero: some View {
        Button {
            QuickCaptureRouter.shared.open()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "text.cursor")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SCTheme.accent)
                    Text("Remember something…")
                        .font(SCTheme.displayFont(17, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Deliberately separate tap targets layered on the card.
                    Button {
                        QuickCaptureRouter.shared.open(QuickCaptureRequest(startRecording: true))
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SCTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(SCTheme.accent.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    Button {
                        QuickCaptureRouter.shared.open()
                    } label: {
                        Image(systemName: "photo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SCTheme.accent)
                            .frame(width: 36, height: 36)
                            .background(SCTheme.accent.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.pressable)
                }
                if !recentCaptureAvatars.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(recentCaptureAvatars) { person in
                            Button {
                                QuickCaptureRouter.shared.open(person: person)
                            } label: {
                                PersonAvatarView(person: person, size: 26)
                            }
                            .buttonStyle(.pressable)
                        }
                        Text("One sentence is enough. People, dates, and follow-ups sort themselves.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.leading, 4)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill(LinearGradient(colors: [SCTheme.accent.opacity(0.10), .clear],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous)
                    .strokeBorder(SCTheme.accent.opacity(0.22))
            }
            .cardShadow()
        }
        .buttonStyle(.pressable)
    }

    /// Less-frequent actions, deliberately quieter than the capture hero.
    private var secondaryActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            Button { showAddPerson = true } label: {
                QuickActionLabel(icon: "person.badge.plus", label: "Contact", color: SCTheme.Accents.primary)
            }.buttonStyle(.pressable)
            Button { showAddEvent = true } label: {
                QuickActionLabel(icon: "calendar.badge.plus", label: "Event", color: SCTheme.Accents.warm)
            }.buttonStyle(.pressable)
            NavigationLink { StrategyView() } label: {
                QuickActionLabel(icon: "wand.and.stars", label: "Strategy", color: SCTheme.Accents.primary)
            }.buttonStyle(.pressable)
            Menu {
                Button { showContactPicker = true } label: {
                    Label("Import Contacts", systemImage: "person.crop.circle.badge.plus")
                }
                Button { showImport = true } label: {
                    Label("Import a Message", systemImage: "square.and.arrow.down")
                }
                Button { showAddInteraction = true } label: {
                    Label("Detailed Log", systemImage: "plus.bubble")
                }
                Button { showVoiceCapture = true } label: {
                    Label("Long Voice Note", systemImage: "waveform")
                }
            } label: {
                QuickActionLabel(icon: "ellipsis", label: "More", color: SCTheme.Accents.cool)
            }
        }
    }

    /// Shown only while unresolved captures exist: small, exception-driven.
    private var needsContextCard: some View {
        FormSectionCard("Needs Context", icon: "person.fill.questionmark") {
            ForEach(capturesNeedingContext.prefix(2), id: \.persistentModelID) { capture in
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(capture.preview)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    CaptureCandidateChips(capture: capture)
                }
            }
            if capturesNeedingContext.count > 2 {
                NavigationLink { CaptureInboxView() } label: {
                    Label("All unresolved (\(capturesNeedingContext.count))", systemImage: "arrow.right")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    /// Shown only when something actually failed.
    private var failedCapturesCard: some View {
        FormSectionCard("Couldn't Process", icon: "exclamationmark.triangle") {
            ForEach(failedCaptures.prefix(2), id: \.persistentModelID) { capture in
                CaptureRowView(capture: capture)
            }
            if failedCaptures.count > 2 {
                NavigationLink { CaptureInboxView() } label: {
                    Label("All failed (\(failedCaptures.count))", systemImage: "arrow.right")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private var recentCapturesCard: some View {
        FormSectionCard("Recent Captures", icon: "sparkles") {
            ForEach(recentCaptures.prefix(3), id: \.persistentModelID) { capture in
                CaptureRowView(capture: capture, showsCandidates: false)
            }
            NavigationLink { CaptureInboxView() } label: {
                Label("All captures", systemImage: "arrow.right")
                    .font(.subheadline.weight(.medium))
            }
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
                .font(SCTheme.displayFont(15, weight: .semibold))
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
                .font(SCTheme.displayFont(24, weight: .bold))
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
