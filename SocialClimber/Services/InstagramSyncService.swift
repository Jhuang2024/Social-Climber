import Foundation
import SwiftData

/// Orchestrates one Instagram sync: pulls the newest export zip(s) from
/// Google Drive, parses followers/following and message threads, records a
/// follower snapshot + follow/unfollow events immediately (they're plain
/// facts), and returns message-thread candidates for the user to review
/// before anything touches People or the timeline.
@MainActor
@Observable
final class InstagramSyncService {
    static let shared = InstagramSyncService()

    nonisolated static let folderDefaultsKey = "instagramDriveFolder"
    /// Purely a "when did I last run a sync" timestamp for the Settings
    /// display; it does not gate which messages are offered. See
    /// `threadCutoffsDefaultsKey` for the thing that actually controls that.
    nonisolated static let lastSyncRunDefaultsKey = "instagramLastSyncRunAt"
    /// Per-conversation high-water marks: `[threadKey: epochSeconds]`. Keyed
    /// per thread (not one global cutoff) so declining to apply one
    /// conversation can never advance past, and silently drop, another
    /// conversation's unreviewed messages, the way a single shared cutoff
    /// would.
    nonisolated static let threadCutoffsDefaultsKey = "instagramThreadCutoffs"
    /// With no previous sync of a given conversation, only messages from the
    /// last N days are offered: a first sync shouldn't dump years of DM
    /// history into the review sheet.
    private static let firstSyncWindowDays = 30
    /// Snapshots beyond this count are pruned oldest-first; events derived
    /// from them are kept forever.
    private static let maxSnapshots = 60

    private(set) var isSyncing = false
    private(set) var progressText = ""

    private init() {}

    /// The last time a sync ran at all, applied or not, shown in Settings.
    var lastSyncAt: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.lastSyncRunDefaultsKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private func threadCutoffs() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: Self.threadCutoffsDefaultsKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func setThreadCutoff(_ date: Date, for key: String) {
        var raw = UserDefaults.standard.dictionary(forKey: Self.threadCutoffsDefaultsKey) as? [String: Double] ?? [:]
        if date.timeIntervalSince1970 > (raw[key] ?? 0) {
            raw[key] = date.timeIntervalSince1970
            UserDefaults.standard.set(raw, forKey: Self.threadCutoffsDefaultsKey)
        }
    }

    // MARK: Result types

    /// One conversation found in the export with messages newer than the
    /// last sync, waiting for user review. `matchedPerson` is the app's
    /// best guess; the review sheet lets the user change or clear it.
    struct ThreadCandidate: Identifiable {
        let id = UUID()
        let title: String
        /// The other participant's name (empty for unmatched group chats).
        let otherParticipant: String
        let messages: [InstagramExportParser.Message]
        var matchedPerson: Person?
        /// Stable per-conversation key (sorted participant names) this
        /// candidate's cutoff advances on apply. See `threadCutoffsDefaultsKey`.
        let threadKey: String

        var latestDate: Date { messages.map(\.date).max() ?? .now }

        /// The conversation rendered as plain "Name: text" lines, what
        /// gets AI-extracted and stored as the interaction's raw import
        /// text, same shape as a pasted chat.
        var digestText: String {
            messages.map { "\($0.sender): \($0.text)" }.joined(separator: "\n")
        }
    }

    struct SyncResult {
        var newFollowers: [String] = []
        var lostFollowers: [String] = []
        var threads: [ThreadCandidate] = []
        var followerCount = 0
        var followingCount = 0
        /// True when the export contained no follower lists (e.g. the
        /// scheduled export was configured to include only messages).
        var hadFollowerData = false
    }

    // MARK: Sync

    func sync(people: [Person], context: ModelContext) async throws -> SyncResult {
        guard !isSyncing else { throw GoogleDriveError.requestFailed }
        isSyncing = true
        defer { isSyncing = false; progressText = "" }

        progressText = "Looking for the latest export in Drive…"
        let folderName = UserDefaults.standard.string(forKey: Self.folderDefaultsKey) ?? ""
        let source = try await GoogleDriveService.shared.latestInstagramExport(folderName: folderName)
        guard !source.isEmpty else { throw GoogleDriveError.noExportFound }

        var localURLs: [URL] = []
        defer { for url in localURLs { try? FileManager.default.removeItem(at: url) } }
        var archives: [URL] = []
        var looseFiles: [(path: String, url: URL)] = []
        let totalFiles = source.archives.count + source.looseFiles.count
        var downloadedCount = 0
        for file in source.archives {
            downloadedCount += 1
            progressText = "Downloading export (\(downloadedCount) of \(totalFiles))…"
            let url = try await GoogleDriveService.shared.downloadToTemporaryFile(
                fileID: file.id,
                filename: file.name
            )
            localURLs.append(url)
            archives.append(url)
        }
        for file in source.looseFiles {
            downloadedCount += 1
            progressText = "Downloading export data (\(downloadedCount) of \(totalFiles))…"
            let url = try await GoogleDriveService.shared.downloadToTemporaryFile(
                fileID: file.id,
                filename: file.name
            )
            localURLs.append(url)
            looseFiles.append((file.relativePath, url))
        }

        // Unzipping and JSON parsing are CPU-bound; keep them off the main
        // actor so the UI stays responsive during a big export.
        progressText = "Reading export…"
        let archiveURLs = archives
        let expandedFiles = looseFiles
        let export = try await Task.detached(priority: .userInitiated) {
            var export = InstagramExportParser.Export()
            for url in archiveURLs {
                let reader = try ZipArchiveReader(url: url)
                defer { reader.close() }
                for entry in reader.entries where InstagramExportParser.isRelevantEntry(entry.name) {
                    guard let data = try? reader.data(for: entry) else { continue }
                    InstagramExportParser.ingest(path: entry.name, data: data, into: &export)
                }
            }
            for file in expandedFiles {
                guard let data = try? Data(contentsOf: file.url) else { continue }
                InstagramExportParser.ingest(path: file.path, data: data, into: &export)
            }
            return export
        }.value

        progressText = "Comparing followers…"
        var result = SyncResult()
        applyFollowerDiff(export: export, into: &result, context: context)

        progressText = "Collecting new messages…"
        buildThreadCandidates(export: export, people: people, into: &result)

        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastSyncRunDefaultsKey)
        try? context.save()
        return result
    }

    /// Advances each applied conversation's own cutoff to its latest
    /// message. Called only for candidates the user actually applied, and
    /// only after they applied: a conversation left unchecked, or a sheet
    /// that's cancelled outright, keeps its old cutoff so those messages are
    /// offered again next sync instead of being silently skipped forever.
    func commitAppliedCutoffs(for candidates: [ThreadCandidate]) {
        for candidate in candidates {
            setThreadCutoff(candidate.latestDate, for: candidate.threadKey)
        }
    }

    // MARK: Follower diff

    private func applyFollowerDiff(export: InstagramExportParser.Export, into result: inout SyncResult, context: ModelContext) {
        let followers = Set(export.followerLists.followers)
        let following = Set(export.followerLists.following)
        guard !followers.isEmpty || !following.isEmpty else { return }
        result.hadFollowerData = true

        let previous = (try? context.fetch(
            FetchDescriptor<FollowerSnapshot>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)])
        )) ?? []
        let last = previous.first

        // Each side is diffed only when this export actually contains it:
        // a messages-only export (or one corrupt part-zip) must never be
        // read as "everyone unfollowed you". A missing side carries the
        // previous snapshot's values forward so the baseline stays honest.
        if !followers.isEmpty, let last {
            let lastFollowers = Set(last.followerUsernames)
            let gained = followers.subtracting(lastFollowers).sorted()
            let lost = lastFollowers.subtracting(followers).sorted()
            result.newFollowers = gained
            result.lostFollowers = lost
            for username in gained { context.insert(FollowerEvent(username: username, kind: .gainedFollower)) }
            for username in lost { context.insert(FollowerEvent(username: username, kind: .lostFollower)) }
        }
        if !following.isEmpty, let last {
            let lastFollowing = Set(last.followingUsernames)
            for username in following.subtracting(lastFollowing).sorted() {
                context.insert(FollowerEvent(username: username, kind: .startedFollowing))
            }
            for username in lastFollowing.subtracting(following).sorted() {
                context.insert(FollowerEvent(username: username, kind: .stoppedFollowing))
            }
        }

        let effectiveFollowers = followers.isEmpty ? Set(last?.followerUsernames ?? []) : followers
        let effectiveFollowing = following.isEmpty ? Set(last?.followingUsernames ?? []) : following
        result.followerCount = effectiveFollowers.count
        result.followingCount = effectiveFollowing.count
        context.insert(FollowerSnapshot(
            followerUsernames: effectiveFollowers.sorted(),
            followingUsernames: effectiveFollowing.sorted()
        ))

        // Prune oldest snapshots beyond the cap (events derived from them
        // stay, since they're the durable history).
        let excess = previous.count + 1 - Self.maxSnapshots
        if excess > 0 {
            for snapshot in previous.suffix(excess) {
                context.delete(snapshot)
            }
        }
    }

    // MARK: Thread candidates

    private func buildThreadCandidates(export: InstagramExportParser.Export, people: [Person], into result: inout SyncResult) {
        // Only used for a conversation with no stored cutoff yet, i.e. the
        // first time it's ever appeared in a sync.
        let fallbackCutoff = Calendar.current.date(byAdding: .day, value: -Self.firstSyncWindowDays, to: .now)
            ?? .distantPast
        let cutoffs = threadCutoffs()
        let owner = export.ownerName

        for thread in export.threads {
            let key = threadKey(for: thread)
            let cutoff = cutoffs[key] ?? fallbackCutoff
            let fresh = thread.messages.filter { $0.date > cutoff }
            guard !fresh.isEmpty else { continue }
            let others = Set(thread.participants).subtracting([owner].compactMap { $0 })
            // Skip notes-to-self threads: with no other participant the
            // title is the owner's own name, which could otherwise
            // auto-match a Person who happens to share it.
            if owner != nil && others.isEmpty { continue }
            let otherParticipant = others.count == 1 ? (others.first ?? "") : ""
            let displayTitle = thread.title.isEmpty ? (otherParticipant.isEmpty ? "Group chat" : otherParticipant) : thread.title

            result.threads.append(ThreadCandidate(
                title: displayTitle,
                otherParticipant: otherParticipant,
                messages: fresh,
                matchedPerson: match(nameOrUsername: otherParticipant.isEmpty ? displayTitle : otherParticipant, people: people),
                threadKey: key
            ))
        }
        result.threads.sort { $0.latestDate > $1.latestDate }
    }

    /// A conversation's stable identity across syncs: its participants
    /// (order-independent), since Instagram's export carries no immutable
    /// thread id. Falls back to the thread title only when participants are
    /// missing (unexpected but not impossible in a malformed export), so a
    /// thread with no other identifying data still gets a consistent key
    /// rather than silently losing its cutoff every sync.
    private func threadKey(for thread: InstagramExportParser.Thread) -> String {
        let participants = thread.participants.map { normalize($0) }.sorted().joined(separator: "|")
        return participants.isEmpty ? "title:\(normalize(thread.title))" : participants
    }

    /// Best-effort match of an export participant to an existing Person:
    /// explicit Instagram username first, then an "Instagram" contact
    /// method, then plain name/nickname equality.
    func match(nameOrUsername: String, people: [Person]) -> Person? {
        let needle = normalize(nameOrUsername)
        guard !needle.isEmpty else { return nil }
        if let byUsername = people.first(where: { normalize($0.instagramUsername) == needle }) {
            return byUsername
        }
        if let byContactMethod = people.first(where: { person in
            person.contactMethods.contains {
                $0.label.localizedCaseInsensitiveContains("instagram") && normalize($0.value) == needle
            }
        }) {
            return byContactMethod
        }
        return people.first {
            normalize($0.name) == needle || (!$0.nickname.isEmpty && normalize($0.nickname) == needle)
        }
    }

    private func normalize(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
    }

    // MARK: Apply

    /// Applies one approved thread candidate: runs the conversation through
    /// the same extraction pipeline voice notes use, logs an imported
    /// Instagram interaction, updates the person's profile, and remembers
    /// the person's Instagram identity for future syncs.
    func apply(candidate: ThreadCandidate, to person: Person, context: ModelContext) async {
        let digest = candidate.digestText
        let outcome = await AIExtractionCoordinator.extract(
            from: digest,
            knownPeople: [person.displayName]
        )
        let interaction = ExtractionApplier.apply(
            outcome.extraction,
            to: [person],
            sourceText: digest,
            interactionType: .socialMedia,
            date: candidate.latestDate,
            quality: 3,
            options: .allApproved(for: outcome.extraction),
            context: context
        )
        interaction?.isImported = true
        interaction?.platform = .instagram
        interaction?.rawImportText = digest

        if person.instagramUsername.isEmpty, !candidate.otherParticipant.isEmpty {
            // Thread participants are display names, not handles; only
            // store it when it looks like a handle (no spaces).
            let normalized = normalize(candidate.otherParticipant)
            if !normalized.contains(" ") {
                person.instagramUsername = normalized
            }
        }
    }
}
