import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var allPeople: [Person]
    @Query(sort: \Interaction.date, order: .reverse) private var interactions: [Interaction]
    @Query private var reminders: [Reminder]
    @Query private var giftIdeas: [GiftIdea]
    @Query private var importantDates: [ImportantDate]

    @State private var showAddPerson = false
    @State private var showAddInteraction = false
    @State private var showVoiceCapture = false
    @State private var showContactPicker = false
    @State private var message: String?

    private var people: [Person] { allPeople.filter { !$0.isArchived } }

    private var checkInsDue: [Person] {
        people.filter { $0.status == .checkInSoon }
            .sorted { $0.priority > $1.priority }
    }

    private var quietPeople: [Person] {
        people.filter { $0.status == .goingQuiet || $0.status == .dormant }
            .sorted { RelationshipHealth.score(for: $0) < RelationshipHealth.score(for: $1) }
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

    private var dueReminders: [Reminder] {
        reminders.filter { !$0.completed && $0.dueDate.daysFromNow <= 3 }
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
                        dashboardPulse
                        quickActions
                        if !dueReminders.isEmpty { remindersCard }
                        if !checkInsDue.isEmpty { checkInsCard }
                        if !upcomingBirthdays.isEmpty { birthdaysCard }
                        if !upcomingPlans.isEmpty { plansCard }
                        if !openGifts.isEmpty { giftsCard }
                        if !quietPeople.isEmpty { quietCard }
                        if !interactions.isEmpty { recentCard }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .socialClimberPageBackground()
            .navigationTitle(greeting)
            .sheet(isPresented: $showAddPerson) { PersonEditView() }
            .sheet(isPresented: $showAddInteraction) { AddInteractionView() }
            .sheet(isPresented: $showVoiceCapture) { VoiceCaptureView() }
            .sheet(isPresented: $showContactPicker) {
                ContactPickerView { contact in
                    let person = ContactsImporter.person(from: contact)
                    context.insert(person)
                    message = "Imported \(person.displayName)."
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
                Text("Social Climber is ready when you add a person, log a memory, import one selected contact, or record a live conversation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                EmptyActionButton(icon: "person.badge.plus", title: "Add person", color: .blue) { showAddPerson = true }
                EmptyActionButton(icon: "plus.bubble.fill", title: "Add interaction", color: .green) { showAddInteraction = true }
                EmptyActionButton(icon: "person.crop.circle.badge.plus", title: "Import contact", color: .orange) { showContactPicker = true }
                EmptyActionButton(icon: "waveform", title: "Voice note", color: .purple) { showVoiceCapture = true }
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

    private var dashboardPulse: some View {
        HStack(spacing: 10) {
            PulseMetric(title: "People", value: "\(people.count)", icon: "person.2.fill", color: .blue)
            PulseMetric(title: "Due", value: "\(dueReminders.count)", icon: "bell.badge.fill", color: .orange)
            PulseMetric(title: "Quiet", value: "\(quietPeople.count)", icon: "moon.zzz.fill", color: .purple)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            QuickActionButton(icon: "person.badge.plus", label: "Person", color: .blue) { showAddPerson = true }
            QuickActionButton(icon: "plus.bubble.fill", label: "Interaction", color: .green) { showAddInteraction = true }
            QuickActionButton(icon: "waveform", label: "Voice Note", color: .purple) { showVoiceCapture = true }
        }
    }

    private var remindersCard: some View {
        FormSectionCard("Due Now", icon: "bell.badge.fill") {
            ForEach(dueReminders.prefix(4)) { reminder in
                ReminderRowView(reminder: reminder)
            }
            NavigationLink("All reminders") { RemindersView() }
                .font(.subheadline.weight(.medium))
        }
    }

    private var checkInsCard: some View {
        FormSectionCard("Check In Soon", icon: "bubble.left.and.bubble.right.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(checkInsDue.prefix(8)) { person in
                        NavigationLink(value: person) {
                            PersonMiniCard(person: person)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationDestination(for: Person.self) { PersonProfileView(person: $0) }
    }

    private var birthdaysCard: some View {
        FormSectionCard("Upcoming Birthdays", icon: "birthday.cake.fill") {
            ForEach(upcomingBirthdays.prefix(5), id: \.0.persistentModelID) { person, date in
                NavigationLink { PersonProfileView(person: person) } label: {
                    HStack {
                        PersonAvatarView(person: person, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(date.formatted(.dateTime.month(.wide).day()))
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
        }
    }

    private var plansCard: some View {
        FormSectionCard("Upcoming Plans", icon: "calendar.badge.clock") {
            ForEach(upcomingPlans.prefix(4)) { reminder in
                ReminderRowView(reminder: reminder)
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
        FormSectionCard("Going Quiet", icon: "moon.zzz.fill") {
            ForEach(quietPeople.prefix(4)) { person in
                NavigationLink { PersonProfileView(person: person) } label: {
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
        FormSectionCard("Recent Activity", icon: "clock.arrow.circlepath") {
            ForEach(interactions.prefix(5)) { interaction in
                NavigationLink { InteractionDetailView(interaction: interaction) } label: {
                    TimelineRowView(interaction: interaction)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.headline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(label)
                    .font(.caption.weight(.medium))
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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

private struct PulseMetric: View {
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
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
