import SwiftUI
import SwiftData
import Charts

/// The big-picture page: an explainable aggregate score for your whole
/// social life, follower gains/losses from Instagram syncs, activity
/// momentum, and the relationships pulling the score down.
struct SocialHealthView: View {
    @Query(sort: \Person.name) private var people: [Person]
    @Query(sort: \Interaction.date, order: .reverse) private var interactions: [Interaction]
    @Query(sort: \FollowerEvent.date, order: .reverse) private var followerEvents: [FollowerEvent]
    @Query(sort: \FollowerSnapshot.takenAt, order: .reverse) private var followerSnapshots: [FollowerSnapshot]

    private var googleDrive: GoogleDriveService { GoogleDriveService.shared }
    private var latestFollowerSnapshot: FollowerSnapshot? { followerSnapshots.first }

    private var report: SocialHealthReport {
        cachedReport ?? SocialHealthReport.compute(
            people: people,
            interactions: interactions,
            followerEvents: followerEvents
        )
    }

    private var coolingPeople: [Person] {
        people.filter { !$0.isArchived && ($0.status == .goingQuiet || $0.status == .dormant) }
            .sorted { $0.priority > $1.priority }
    }

    @State private var ringProgress: CGFloat = 0
    @State private var chartRange: HealthChartRange = .month
    @State private var cachedReport: SocialHealthReport?
    @State private var cachedTrendPoints: [HealthChartPoint] = []

    var body: some View {
        ScrollView {
            VStack(spacing: SCTheme.pageSpacing) {
                if people.isEmpty {
                    emptyState
                } else {
                    scoreCard
                    trendCard
                    factorsCard
                    if googleDrive.isConnected || latestFollowerSnapshot != nil { instagramCard }
                    momentumCard
                    if !coolingPeople.isEmpty { coolingCard }
                    if !googleDrive.isConnected && latestFollowerSnapshot == nil { instagramHint }
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .socialClimberPageBackground()
        .navigationTitle("Social Health")
        .navigationBarTitleDisplayMode(.large)
        // Person rows here push their destination directly. Registering
        // `.navigationDestination(for: Person.self)` again on this pushed
        // screen would conflict with the Dashboard root's, and value links
        // resolved from a pushed screen have proven unreliable (see
        // DashboardPeopleListView).
        .onAppear {
            rebuildHealthData()
        }
        .onChange(of: chartRange) {
            rebuildTrendPoints()
        }
        .onChange(of: chartDataRevision) {
            rebuildHealthData()
        }
    }

    // MARK: Trend

    /// A cheap change token. Dragging the chart does not touch this parent
    /// state, while real data changes rebuild the cached series once.
    private var chartDataRevision: HealthChartDataRevision {
        HealthChartDataRevision(
            peopleCount: people.count,
            interactionCount: interactions.count,
            latestInteraction: interactions.first?.date,
            followerEventCount: followerEvents.count,
            latestFollowerEvent: followerEvents.first?.date
        )
    }

    private func rebuildHealthData() {
        let current = SocialHealthReport.compute(
            people: people,
            interactions: interactions,
            followerEvents: followerEvents
        )
        cachedReport = current
        cachedTrendPoints = makeTrendPoints()
        withAnimation(.snappy(duration: 0.8)) {
            ringProgress = CGFloat(current.total) / 100
        }
    }

    private func rebuildTrendPoints() {
        cachedTrendPoints = makeTrendPoints()
    }

    /// Historical scoring is intentionally performed only when the range or
    /// underlying data changes. The old computed property ran this full loop
    /// several times for every finger movement on the chart.
    private func makeTrendPoints() -> [HealthChartPoint] {
        let calendar = Calendar.current
        let end = Date.now
        let earliestFact = ([people.map(\.createdAt), interactions.map(\.date), followerEvents.map(\.date)]
            .flatMap { $0 }
            .min()) ?? end
        let requestedStart: Date
        let stepDays: Int
        switch chartRange {
        case .week:
            requestedStart = calendar.date(byAdding: .day, value: -6, to: end) ?? end
            stepDays = 1
        case .month:
            requestedStart = calendar.date(byAdding: .day, value: -29, to: end) ?? end
            stepDays = 1
        case .year:
            requestedStart = calendar.date(byAdding: .day, value: -364, to: end) ?? end
            stepDays = 7
        case .all:
            requestedStart = earliestFact
            let span = max(1, calendar.dateComponents([.day], from: earliestFact, to: end).day ?? 1)
            stepDays = max(1, Int(ceil(Double(span) / 60.0)))
        }
        let start = max(requestedStart, earliestFact)
        var dates: [Date] = []
        var cursor = start
        while cursor < end {
            dates.append(cursor)
            cursor = calendar.date(byAdding: .day, value: stepDays, to: cursor) ?? end
        }
        dates.append(end)
        return dates.map { date in
            HealthChartPoint(
                date: date,
                score: SocialHealthReport.compute(
                    people: people,
                    interactions: interactions,
                    followerEvents: followerEvents,
                    now: date
                ).total
            )
        }
    }

    private var trendCard: some View {
        SocialHealthTrendCard(
            points: cachedTrendPoints,
            color: report.band.color,
            range: $chartRange
        )
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

    private var instagramCard: some View {
        FormSectionCard("Instagram", icon: "camera.fill") {
            if googleDrive.isConnected {
                InstagramSyncControl(style: .inline)
            }
            if let snapshot = latestFollowerSnapshot {
                HStack {
                    Label(googleDrive.isConnected ? "Drive connected" : "Last saved snapshot", systemImage: googleDrive.isConnected ? "checkmark.circle.fill" : "externaldrive")
                        .foregroundStyle(googleDrive.isConnected ? SCTheme.Accents.growth : Color.secondary)
                    Spacer()
                    Text("Updated \(snapshot.takenAt.relativeLabel)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.medium))

                Text("Monthly Meta exports are treated as dated activity, not as your total audience. Social Climber records the usernames Meta includes and never treats someone missing from the next partial export as an unfollow.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Meta does not include a “who unfollowed you” record in monthly partial exports. That one change type requires two complete snapshots; followed you, you followed, and Meta's recently-unfollowed list are still person-level.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Sync once to save the first follower/following baseline. The first list is a baseline—not followers gained that day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                    NavigationLink {
                        PersonProfileView(person: person)
                    } label: {
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
            Text("Connect Google Drive in Settings, then sync from here or the Home screen. From the second snapshot onward, Social Health records exactly who followed or unfollowed you and who you followed or unfollowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private enum HealthChartRange: String, CaseIterable, Identifiable {
    case week, month, year, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        }
    }
}

private struct HealthChartPoint: Identifiable {
    let date: Date
    let score: Int
    var id: Date { date }
}

private struct HealthChartDataRevision: Equatable {
    let peopleCount: Int
    let interactionCount: Int
    let latestInteraction: Date?
    let followerEventCount: Int
    let latestFollowerEvent: Date?
}

/// Owns the high-frequency drag selection state so moving a finger only
/// invalidates this small chart, not the entire Social Health screen.
private struct SocialHealthTrendCard: View {
    let points: [HealthChartPoint]
    let color: Color
    @Binding var range: HealthChartRange
    @State private var selectedDate: Date?

    private var selectedPoint: HealthChartPoint? {
        guard !points.isEmpty else { return nil }
        guard let selectedDate else { return points.last }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate))
                < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        FormSectionCard("Score Trend", icon: "chart.xyaxis.line") {
            Picker("Range", selection: $range) {
                ForEach(HealthChartRange.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: range) { selectedDate = nil }

            if let selectedPoint {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(selectedPoint.score)")
                        .font(SCTheme.displayFont(28, weight: .bold))
                        .monospacedDigit()
                    Text("of 100")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(selectedPoint.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }

            if points.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
            } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Score", point.score)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.28), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Score", point.score)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    if let selectedPoint {
                        RuleMark(x: .value("Selected", selectedPoint.date))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                        PointMark(
                            x: .value("Selected date", selectedPoint.date),
                            y: .value("Selected score", selectedPoint.score)
                        )
                        .foregroundStyle(color)
                        .symbolSize(70)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100])
                }
                .chartXSelection(value: $selectedDate)
                .frame(height: 190)
            }

            Text("Drag across the chart to inspect the exact score for any point.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    NavigationStack { SocialHealthView() }
        .modelContainer(PreviewData.container)
}
