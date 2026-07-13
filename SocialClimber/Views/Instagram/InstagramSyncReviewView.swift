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
                        Text("No new messages since the last sync.")
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
                        Button("Apply") { applyAll() }
                            .disabled(!decisions.contains { $0.include && ($0.person != nil || $0.createNew) })
                    }
                }
            }
            .interactiveDismissDisabled(isApplying)
            .overlay {
                if isApplying {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(applyProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                LabeledContent("Followers", value: "\(result.followerCount)")
                LabeledContent("Following", value: "\(result.followingCount)")
                if !result.newFollowers.isEmpty {
                    followerChangeRow(
                        label: "New followers",
                        usernames: result.newFollowers,
                        color: .green,
                        icon: "person.badge.plus"
                    )
                }
                if !result.lostFollowers.isEmpty {
                    followerChangeRow(
                        label: "Unfollowed you",
                        usernames: result.lostFollowers,
                        color: .red,
                        icon: "person.badge.minus"
                    )
                }
                if result.newFollowers.isEmpty && result.lostFollowers.isEmpty {
                    Text("No follower changes since the last sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func followerChangeRow(label: String, usernames: [String], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(label) (\(usernames.count))", systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(usernames.map { "@\($0)" }.joined(separator: ", "))
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
                    HStack {
                        Image(systemName: "person.crop.circle")
                        if decision.wrappedValue.createNew {
                            Text("New person: \(candidate.title)")
                        } else if let person = decision.wrappedValue.person {
                            Text(person.displayName)
                        } else {
                            Text("Choose person…")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                Text(previewText(candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
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
            try? context.save()
            Haptics.success()
            isApplying = false
            dismiss()
        }
    }
}
