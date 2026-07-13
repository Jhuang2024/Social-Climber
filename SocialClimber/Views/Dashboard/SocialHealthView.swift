import SwiftUI
import SwiftData

/// The big-picture page: an explainable aggregate score for your whole
/// social life, follower gains/losses from Instagram syncs, activity
/// momentum, and the relationships pulling the score down.
struct SocialHealthView: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Interaction.date, order: .reverse) private var interactions: [Interaction]
    @Query(sort: \FollowerEvent.date, order: .reverse) private var followerEvents: [FollowerEvent]

    private var report: SocialHealthReport {
        SocialHealthReport.compute(people: people, interactions: interactions, followerEvents: followerEvents)
    }

    private var recentEvents: [FollowerEvent] {
        followerEvents.filter { $0.date.daysAgo <= 30 }
    }

    private var unfollowers: [FollowerEvent] {
        recentEvents.filter { $0.kind == .lostFollower }
    }

    private var newFollowers: [FollowerEvent] {
        recentEvents.filter { $0.kind == .gainedFollower }
    }

    private var coolingPeople: [Person] {
        people.filter { !$0.isArchived && ($0.status == .goingQuiet || $0.status == .dormant) }
            .sorted { $0.priority > $1.priority }
    }

    @State private var ringProgress: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: SCTheme.pageSpacing) {
                if people.isEmpty {
                    emptyState
                } else {
                    scoreCard
                    factorsCard
                    if !unfollowers.isEmpty { unfollowersCard }
                    if !newFollowers.isEmpty { newFollowersCard }
                    momentumCard
                    if !coolingPeople.isEmpty { coolingCard }
                    if followerEvents.isEmpty { instagramHint }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Social Health")
        .navigationBarTitleDisplayMode(.large)
        // Person NavigationLinks here resolve through the Dashboard
        // NavigationStack's existing `.navigationDestination(for: Person.self)`;
        // registering it again on this pushed screen would conflict.
        .onAppear {
            withAnimation(.snappy(duration: 0.8)) {
                ringProgress = CGFloat(report.total) / 100
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "heart.text.square",
            title: "No score yet",
            message: "Add a few people and log some interactions; your social health score builds itself from them."
        )
        .padding(.top, 40)
    }

    // MARK: Score

    private var scoreCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // A soft halo behind the ring, the same jewellery treatment
                // the avatars and empty states wear.
                Circle()
                    .fill(report.band.color.opacity(0.10))
                    .frame(width: 168, height: 168)
                    .blur(radius: 10)
                Circle()
                    .stroke(report.band.color.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(report.band.color.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    // Serif display digits: the same editorial face as
                    // person names and the masthead.
                    Text("\(report.total)")
                        .font(SCTheme.displayFont(48, weight: .bold))
                        .contentTransition(.numericText())
                    Text("of 100")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
            }
            .frame(width: 150, height: 150)
            .padding(.top, 10)

            Label(report.band.label, systemImage: report.band.icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(report.band.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(report.band.color.opacity(0.12), in: Capsule())

            Text("Built from your relationship scores, this month's activity, and your Instagram follower trend. Every point is itemized below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .scCard()
    }

    private var factorsCard: some View {
        FormSectionCard("Why This Score", icon: "list.bullet.rectangle.fill") {
            VStack(spacing: 10) {
                ForEach(report.rankedFactors) { factor in
                    HStack(spacing: 10) {
                        Image(systemName: factor.isPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(factor.isPositive ? SCTheme.Accents.growth : SCTheme.Accents.alert)
                            .frame(width: 18, height: 18)
                            .background(
                                (factor.isPositive ? SCTheme.Accents.growth : SCTheme.Accents.alert).opacity(0.14),
                                in: Circle()
                            )
                        Text(factor.label)
                            .font(.caption)
                        Spacer()
                        Text(factor.signedString)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(factor.isPositive ? SCTheme.Accents.growth : SCTheme.Accents.alert)
                    }
                }
            }
        }
    }

    // MARK: Followers

    private var unfollowersCard: some View {
        FormSectionCard("Unfollowed You (30 days)", icon: "person.badge.minus") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(unfollowers.prefix(12), id: \.persistentModelID) { event in
                    followerEventRow(event)
                }
                if unfollowers.count > 12 {
                    Text("+ \(unfollowers.count - 12) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var newFollowersCard: some View {
        FormSectionCard("New Followers (30 days)", icon: "person.badge.plus") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(newFollowers.prefix(12), id: \.persistentModelID) { event in
                    followerEventRow(event)
                }
                if newFollowers.count > 12 {
                    Text("+ \(newFollowers.count - 12) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func followerEventRow(_ event: FollowerEvent) -> some View {
        let matched = matchedPerson(for: event.username)
        HStack(spacing: 10) {
            if let matched {
                PersonAvatarView(person: matched, size: 26)
            } else {
                Image(systemName: event.kind.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(event.kind.color)
                    .frame(width: 26, height: 26)
                    .background(event.kind.color.opacity(0.14), in: Circle())
            }
            if let matched {
                NavigationLink(value: matched) {
                    HStack(spacing: 6) {
                        Text(matched.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("@\(event.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text("@\(event.username)")
                    .font(.caption)
            }
            Spacer()
            Text(event.date.relativeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Same matcher the sync uses; keeping the two consistent means a
    /// person matched during import review is also matched here.
    private func matchedPerson(for username: String) -> Person? {
        InstagramSyncService.shared.match(nameOrUsername: username, people: people)
    }

    // MARK: Momentum

    private var momentumCard: some View {
        let recent = interactions.filter { $0.date.daysAgo <= 30 }.count
        let prior = interactions.filter { $0.date.daysAgo > 30 && $0.date.daysAgo <= 60 }.count
        let touched = Set(interactions.filter { $0.date.daysAgo <= 30 }.flatMap { $0.people.map(\.persistentModelID) }).count
        return FormSectionCard("This Month", icon: "chart.line.uptrend.xyaxis") {
            HStack(spacing: 10) {
                momentumStat(value: "\(recent)", label: "interactions")
                momentumStat(value: prior > 0 ? "\(recent >= prior ? "+" : "")\(recent - prior)" : "N/A", label: "vs last month")
                momentumStat(value: "\(touched)", label: "people reached")
            }
        }
    }

    private func momentumStat(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            // Hero numbers get the serif display face, like the score ring.
            Text(value)
                .font(SCTheme.displayFont(20, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(SCTheme.elevatedBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    // MARK: Cooling

    private var coolingCard: some View {
        FormSectionCard("Pulling the Score Down", icon: "thermometer.low") {
            VStack(spacing: 10) {
                ForEach(coolingPeople.prefix(6)) { person in
                    NavigationLink(value: person) {
                        HStack {
                            PersonAvatarView(person: person, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(person.lastContactedAt.map { "Last contact \($0.relativeLabel)" } ?? "No contact logged")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            RelationshipStatusBadge(status: person.status)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var instagramHint: some View {
        FormSectionCard("Instagram", icon: "camera.fill") {
            Text("Connect Google Drive in Settings and run an Instagram sync to see who followed and unfollowed you here; the follower trend then feeds into this score.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { SocialHealthView() }
        .modelContainer(PreviewData.container)
}
