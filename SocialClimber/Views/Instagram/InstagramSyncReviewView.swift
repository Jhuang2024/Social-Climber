import SwiftUI
import SwiftData

/// Review step after an Instagram sync: shows follower changes (already
/// recorded — they're facts) and the conversations with new messages, each
/// matched to a Person where possible. Nothing touches People or the
/// timeline until the user taps Apply, mirroring the voice-note review
/// pattern.
struct InstagramSyncReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]

    let result: InstagramSyncService.SyncResult

    /// Per-thread review state: include it, and who it belongs to.
    struct ThreadDecision: Identifiable {
        let id: UUID
        var candidate: InstagramSyncService.ThreadCandidate
        var include: Bool
        var person: Person?
        var createNew: Bool
    }

    @State private var decisions: [ThreadDecision] = []
    @State private var isApplying = false
    @State private var applyProgress = ""
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                followersSection
                if decisions.isEmpty {
                    Section("Conversations") {
                        Label("No new messages since the last sync.", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach($decisions) { $decision in
                            threadRow($decision)
                        }
                    } header: {
                        Text("New Conversations (\(decisions.count))")
                    } footer: {
                        Text("Included conversations are analyzed with your selected AI provider (or the offline fallback) and logged as Instagram interactions — interests, reminders, and dates found in them are applied to the matched person.")
                    }
                }
            }
            .navigationTitle("Instagram Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isApplying {
                        ProgressView()
                    } else {
                        // Disabled while any included row still says
                        // "Choose person…" — otherwise that conversation
                        // would be silently dropped, and the advanced
                        // cutoff means it never comes back.
                        let readyCount = decisions.filter { $0.include && ($0.person != nil || $0.createNew) }.count
                        Button(readyCount > 0 ? "Apply (\(readyCount))" : "Apply") { applyAll() }
                            .fontWeight(.semibold)
                            .disabled(
                                readyCount == 0
                                    || decisions.contains { $0.include && $0.person == nil && !$0.createNew }
                            )
                    }
                }
            }
            .interactiveDismissDisabled(isApplying)
            .overlay {
                if isApplying {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(applyProgress)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .scCard()
                    .fixedSize()
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                decisions = result.threads.map {
                    ThreadDecision(
                        id: $0.id,
                        candidate: $0,
                        include: $0.matchedPerson != nil,
                        person: $0.matchedPerson,
                        createNew: false
                    )
                }
            }
        }
    }

    // MARK: Followers

    @ViewBuilder
    private var followersSection: some View {
        if result.hadFollowerData {
            Section("Followers") {
                HStack(spacing: 10) {
                    followerStat(value: result.followerCount, label: "followers")
                    followerStat(value: result.followingCount, label: "following")
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                if !result.newFollowers.isEmpty {
                    followerChangeRow(
                        label: "New followers",
                        usernames: result.newFollowers,
                        color: SCTheme.Accents.growth,
                        icon: "person.badge.plus"
                    )
                }
                if !result.lostFollowers.isEmpty {
                    followerChangeRow(
                        label: "Unfollowed you",
                        usernames: result.lostFollowers,
                        color: SCTheme.Accents.alert,
                        icon: "person.badge.minus"
                    )
                }
                if result.newFollowers.isEmpty && result.lostFollowers.isEmpty {
                    Label("No follower changes since the last sync.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func followerStat(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(SCTheme.displayFont(20, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1.0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(SCTheme.elevatedBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func followerChangeRow(label: String, usernames: [String], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.14), in: Circle())
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text("\(usernames.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
            }
            Text(usernames.map { "@\($0)" }.joined(separator: "  "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Threads

    private func threadRow(_ decision: Binding<ThreadDecision>) -> some View {
        let candidate = decision.wrappedValue.candidate
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: decision.include) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(candidate.messages.count) new message\(candidate.messages.count == 1 ? "" : "s") · \(candidate.latestDate.relativeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.green)

            if decision.wrappedValue.include {
                Menu {
                    Button {
                        decision.wrappedValue.createNew = true
                        decision.wrappedValue.person = nil
                    } label: {
                        Label("Create \"\(candidate.title)\"", systemImage: "person.badge.plus")
                    }
                    Divider()
                    ForEach(people) { person in
                        Button(person.displayName) {
                            decision.wrappedValue.person = person
                            decision.wrappedValue.createNew = false
                        }
                    }
                } label: {
                    assignmentLabel(decision.wrappedValue)
                }

                Text(previewText(candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// The current person assignment rendered as a tinted capsule: accent
    /// when resolved, alert-toned while it still needs a choice — the one
    /// state that blocks Apply.
    private func assignmentLabel(_ decision: ThreadDecision) -> some View {
        let needsChoice = decision.person == nil && !decision.createNew
        let tint = needsChoice ? SCTheme.Accents.alert : SCTheme.accent
        return HStack(spacing: 6) {
            if let person = decision.person {
                PersonAvatarView(person: person, size: 18)
                Text(person.displayName)
            } else if decision.createNew {
                Image(systemName: "person.badge.plus")
                    .font(.caption2)
                Text("New: \(decision.candidate.title)")
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.caption2)
                Text("Choose person…")
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.6)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private func previewText(_ candidate: InstagramSyncService.ThreadCandidate) -> String {
        candidate.messages.suffix(2).map { "\($0.sender): \($0.text)" }.joined(separator: "  ·  ")
    }

    // MARK: Apply

    private func applyAll() {
        isApplying = true
        Task {
            let included = decisions.filter { $0.include && ($0.person != nil || $0.createNew) }
            for (index, decision) in included.enumerated() {
                applyProgress = "Applying \(index + 1) of \(included.count)…"
                let person: Person
                if let existing = decision.person {
                    person = existing
                } else {
                    person = Person(name: decision.candidate.title, category: .acquaintance)
                    context.insert(person)
                }
                await InstagramSyncService.shared.apply(
                    candidate: decision.candidate,
                    to: person,
                    context: context
                )
            }
            InstagramSyncService.shared.commitCutoff(result)
            try? context.save()
            Haptics.success()
            isApplying = false
            dismiss()
        }
    }
}
