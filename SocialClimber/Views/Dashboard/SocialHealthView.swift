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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                scoreCard
                factorsCard
                if !unfollowers.isEmpty { unfollowersCard }
                if !newFollowers.isEmpty { newFollowersCard }
                momentumCard
                if !coolingPeople.isEmpty { coolingCard }
                if followerEvents.isEmpty { instagramHint }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Social Health")
        .navigationBarTitleDisplayMode(.large)
        // Person NavigationLinks here resolve through the Dashboard
        // NavigationStack's existing `.navigationDestination(for: Person.self)`
        // — registering it again on this pushed screen would conflict.
    }

    // MARK: Score

    private var scoreCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(report.total) / 100)
                    .stroke(report.band.color.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(report.total)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("of 100")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            .padding(.top, 6)

            Label(report.band.label, systemImage: report.band.icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(report.band.color)

            Text("A transparent aggregate of your relationship scores, how active you've been, and your Instagram follower trend. Every point is explained below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SCTheme.cardRadius, style: .continuous))
    }

    private var factorsCard: some View {
        FormSectionCard("Why This Score", icon: "list.bullet.rectangle.fill") {
            VStack(spacing: 8) {
                ForEach(report.rankedFactors) { factor in
                    HStack {
                        Text(factor.label)
                            .font(.caption)
                        Spacer()
                        Text(factor.signedString)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(factor.isPositive ? .green : .red)
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
        HStack(spacing: 8) {
            Image(systemName: event.kind.icon)
                .font(.caption)
                .foregroundStyle(event.kind.color)
                .frame(width: 20)
            if let matched {
                NavigationLink(value: matched) {
                    HStack(spacing: 6) {
                        Text(matched.displayName)
                            .font(.caption.weight(.semibold))
                        Text("@\(event.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    /// Same matcher the sync uses — keeping the two consistent means a
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
                momentumStat(value: prior > 0 ? "\(recent >= prior ? "+" : "")\(recent - prior)" : "—", label: "vs last month")
                momentumStat(value: "\(touched)", label: "people reached")
            }
        }
    }

    private func momentumStat(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            Text("Connect Google Drive in Settings and run an Instagram sync to see who followed and unfollowed you here — the follower trend then feeds into this score.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { SocialHealthView() }
        .modelContainer(PreviewData.container)
}
