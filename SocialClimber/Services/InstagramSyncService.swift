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
        var followerFileCount = 0
        var followingFileCount = 0
        /// The first complete list creates a baseline; it is not interpreted
        /// as hundreds of people following on the day the feature was enabled.
        var establishedFollowerBaseline = false
        /// True when the export contained no follower lists (e.g. the
        /// scheduled export was configured to include only messages).
        var hadFollowerData = false
    }

    // MARK: Sync

    func sync(people: [Person], context: ModelContext) async throws -> SyncResult {
        guard !isSyncing else { throw GoogleDriveError.requestFailed }
        isSyncing = true
        defer { isSyncing = false; progressText = "" }

        // One-time, idempotent migration for data produced by the original
        // importer, which flattened every AI suggestion directly into the
        // profile and could repeat the same thread before its cutoff saved.
        repairLegacyImportArtifacts(people: people, context: context)

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
        result.followerFileCount = export.followerLists.followerFiles.count
        result.followingFileCount = export.followerLists.followingFiles.count
        let followerBaselineReplacement = last.map {
            Self.isLikelyBaselineReplacement(previous: $0.followerUsernames.count, current: followers.count)
        } ?? false
        let followingBaselineReplacement = last.map {
            Self.isLikelyBaselineReplacement(previous: $0.followingUsernames.count, current: following.count)
        } ?? false
        result.establishedFollowerBaseline = last == nil
            || (!followers.isEmpty && (last?.followerUsernames.isEmpty ?? true))
            || (!following.isEmpty && (last?.followingUsernames.isEmpty ?? true))
            || followerBaselineReplacement
            || followingBaselineReplacement

        // Each side is diffed only when this export actually contains it:
        // a messages-only export (or one corrupt part-zip) must never be
        // read as "everyone unfollowed you". A missing side carries the
        // previous snapshot's values forward so the baseline stays honest.
        if !followers.isEmpty, let last, !last.followerUsernames.isEmpty,
           !followerBaselineReplacement {
            let lastFollowers = Set(last.followerUsernames)
            let gained = followers.subtracting(lastFollowers).sorted()
            let lost = lastFollowers.subtracting(followers).sorted()
            result.newFollowers = gained
            result.lostFollowers = lost
            for username in gained { context.insert(FollowerEvent(username: username, kind: .gainedFollower)) }
            for username in lost { context.insert(FollowerEvent(username: username, kind: .lostFollower)) }
        }
        if !following.isEmpty, let last, !last.followingUsernames.isEmpty,
           !followingBaselineReplacement {
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

    /// A partial/date-limited Meta export followed by a complete export can
    /// jump from tens to thousands of accounts. Treat that as a corrected
    /// baseline, not as 1,400 people following overnight (and vice versa).
    nonisolated static func isLikelyBaselineReplacement(previous: Int, current: Int) -> Bool {
        guard previous > 0, current > 0 else { return false }
        let larger = max(previous, current)
        let smaller = min(previous, current)
        return larger - smaller >= 100 && Double(larger) / Double(smaller) >= 2
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

    /// Applies one approved thread through the app's authoritative capture
    /// pipeline. Instagram messages therefore get the same attribution,
    /// evidence-linked facts, undo, search, summary, timeline, and dedup
    /// behavior as typed/voice captures. Imported conversations are
    /// deliberately conservative: extracted dates, reminders, and gifts are
    /// suggestions until the user confirms them, never immediate profile or
    /// notification mutations.
    func apply(candidate: ThreadCandidate, to person: Person, context: ModelContext) async {
        let digest = candidate.digestText
        let capture = existingInstagramCapture(
            digest: digest,
            date: candidate.latestDate,
            person: person,
            context: context
        ) ?? makeInstagramCapture(
            candidate: candidate,
            person: person,
            context: context
        )

        // Older app versions created the imported interaction directly. If
        // it is already present, backfill capture provenance instead of
        // running extraction again and duplicating the interaction/profile
        // changes on the next Drive sync.
        if let existing = existingInstagramInteraction(
            digest: digest,
            date: candidate.latestDate,
            person: person,
            context: context
        ) {
            if existing.sourceCaptureUUID == nil {
                existing.sourceCaptureUUID = capture.uuid
            }
            finish(capture: capture, person: person, summary: existing.messageSummary)
            rememberInstagramIdentity(candidate: candidate, person: person)
            return
        }

        await CaptureProcessor.shared.process(capture, in: context)
        let interaction = CaptureProcessor.interaction(for: capture, context: context)
        interaction?.isImported = true
        interaction?.platform = .instagram
        interaction?.rawImportText = digest
        if let interaction {
            finish(capture: capture, person: person, summary: interaction.messageSummary)
        }
        rememberInstagramIdentity(candidate: candidate, person: person)
    }

    private func makeInstagramCapture(
        candidate: ThreadCandidate,
        person: Person,
        context: ModelContext
    ) -> CapturedMemory {
        let capture = CapturedMemory(
            rawText: candidate.digestText,
            source: .instagram,
            capturedAt: candidate.latestDate,
            trustedPeople: [person],
            typeHint: .socialMedia
        )
        context.insert(capture)
        return capture
    }

    private func existingInstagramCapture(
        digest: String,
        date: Date,
        person: Person,
        context: ModelContext
    ) -> CapturedMemory? {
        let captures = (try? context.fetch(FetchDescriptor<CapturedMemory>())) ?? []
        return captures.first {
            $0.source == .instagram
                && $0.rawText == digest
                && abs($0.capturedAt.timeIntervalSince(date)) < 1
                && $0.trustedPersonIDs.contains(person.uuid)
        }
    }

    private func existingInstagramInteraction(
        digest: String,
        date: Date,
        person: Person,
        context: ModelContext
    ) -> Interaction? {
        let interactions = (try? context.fetch(FetchDescriptor<Interaction>())) ?? []
        return interactions.first {
            $0.isImported
                && $0.platform == .instagram
                && $0.rawImportText == digest
                && abs($0.date.timeIntervalSince(date)) < 1
                && $0.people.contains(where: { $0.uuid == person.uuid })
        }
    }

    private func finish(
        capture: CapturedMemory,
        person: Person,
        summary: String
    ) {
        capture.resolvedPersonIDs = [person.uuid]
        capture.resolvedPersonNames = [person.name]
        capture.title = "Instagram with \(person.firstName)"
        capture.detail = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported Instagram messages"
            : summary
        capture.errorMessage = ""
        capture.status = .processed
    }

    private func rememberInstagramIdentity(candidate: ThreadCandidate, person: Person) {

        if person.instagramUsername.isEmpty, !candidate.otherParticipant.isEmpty {
            // Thread participants are display names, not handles; only
            // store it when it looks like a handle (no spaces).
            let normalized = normalize(candidate.otherParticipant)
            if !normalized.contains(" ") {
                person.instagramUsername = normalized
            }
        }
    }

    // MARK: Legacy importer repair

    /// Repairs only artifacts carrying strong evidence that the original
    /// Instagram importer created them. The operation is safe to run at the
    /// start of every sync: exact duplicate interactions collapse to one,
    /// flattened AI fields become reviewable `MemoryFact`s, generic dates
    /// and auto-follow-ups are removed, and raw transcript lines are taken
    /// out of Personality. Manually-created data without an Instagram
    /// extraction match is untouched.
    @discardableResult
    func repairLegacyImportArtifacts(people: [Person], context: ModelContext) -> Int {
        var changes = 0
        var imported = ((try? context.fetch(FetchDescriptor<Interaction>())) ?? []).filter {
            $0.isImported && $0.platform == .instagram
        }

        // Old retries could insert one interaction per tap. Prefer a record
        // already linked to a capture, then the oldest original.
        var seen: [String: Interaction] = [:]
        for interaction in imported.sorted(by: {
            if ($0.sourceCaptureUUID != nil) != ($1.sourceCaptureUUID != nil) {
                return $0.sourceCaptureUUID != nil
            }
            return $0.createdAt < $1.createdAt
        }) {
            let peopleKey = interaction.people.map(\.uuid.uuidString).sorted().joined(separator: "|")
            let key = "\(interaction.date.timeIntervalSince1970)|\(peopleKey)|\(interaction.rawImportText)"
            if seen[key] != nil {
                InteractionSaver.reverseClosenessImpact(of: interaction)
                context.delete(interaction)
                changes += 1
            } else {
                seen[key] = interaction
            }
        }
        imported = Array(seen.values)

        // Backfill the durable capture record even when the Drive cutoff has
        // already advanced and the old conversation will never be offered
        // in the review sheet again. This makes existing Instagram imports
        // appear in Recent Captures immediately after the next sync.
        var captures = (try? context.fetch(FetchDescriptor<CapturedMemory>())) ?? []
        for interaction in imported where interaction.sourceCaptureUUID == nil {
            let linkedPeople = interaction.people
            guard !linkedPeople.isEmpty else { continue }
            let matching = captures.first {
                $0.source == .instagram
                    && $0.rawText == interaction.rawImportText
                    && abs($0.capturedAt.timeIntervalSince(interaction.date)) < 1
                    && Set($0.trustedPersonIDs) == Set(linkedPeople.map(\.uuid))
            }
            let capture: CapturedMemory
            if let matching {
                capture = matching
            } else {
                capture = CapturedMemory(
                    rawText: interaction.rawImportText,
                    source: .instagram,
                    capturedAt: interaction.date,
                    trustedPeople: linkedPeople,
                    typeHint: .socialMedia
                )
                context.insert(capture)
                captures.append(capture)
                changes += 1
            }
            capture.resolvedPersonIDs = linkedPeople.map(\.uuid)
            capture.resolvedPersonNames = linkedPeople.map(\.name)
            capture.title = "Instagram with \(linkedPeople.map(\.firstName).joined(separator: " & "))"
            capture.detail = interaction.messageSummary.isEmpty ? "Imported Instagram messages" : interaction.messageSummary
            capture.status = .processed
            interaction.sourceCaptureUUID = capture.uuid
            changes += 1
        }

        let existingFacts = (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []
        var factKeys = Set(existingFacts.map {
            "\($0.person?.uuid.uuidString ?? "none")|\($0.typeRaw)|\($0.value.lowercased())"
        })

        func addSuggestion(_ value: String, type: MemoryFactType, person: Person, interaction: Interaction) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            let key = "\(person.uuid.uuidString)|\(type.rawValue)|\(cleaned.lowercased())"
            guard factKeys.insert(key).inserted else { return }
            let fact = MemoryFact(
                type: type,
                value: cleaned,
                person: person,
                confidence: interaction.aiSummary?.confidence ?? 0.5,
                status: .suggested,
                sourceCaptureUUID: interaction.sourceCaptureUUID,
                sourceInteractionUUID: interaction.uuid
            )
            context.insert(fact)
            changes += 1
        }

        for person in people {
            let personImports = imported.filter { interaction in
                interaction.people.contains(where: { $0.uuid == person.uuid })
            }
            guard !personImports.isEmpty else { continue }

            let rawLines = Set(personImports.flatMap { $0.rawImportText.components(separatedBy: .newlines) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty })

            // Undo flattened AI fields while preserving their useful content
            // as individually rejectable, provenance-linked suggestions.
            var legacyInterests = Set<String>()
            var legacyPersonality = Set<String>()
            for interaction in personImports {
                interaction.followUpNeeded = false
                interaction.followUpDate = nil
                interaction.nextMove = ""
                guard let summary = interaction.aiSummary else { continue }
                for value in summary.interests {
                    legacyInterests.insert(value.lowercased())
                    addSuggestion(value, type: .interest, person: person, interaction: interaction)
                }
                for value in summary.personalityNotes {
                    legacyPersonality.insert(value.lowercased())
                    if !rawLines.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                        addSuggestion(value, type: .personality, person: person, interaction: interaction)
                    }
                }
                for value in summary.giftIdeas {
                    addSuggestion(value, type: .giftIdea, person: person, interaction: interaction)
                }
                for value in summary.importantDates {
                    addSuggestion(value, type: .importantDate, person: person, interaction: interaction)
                }
                for value in summary.reminders {
                    addSuggestion(value, type: .reminderSuggestion, person: person, interaction: interaction)
                }
            }

            let beforeInterests = person.interests.count
            person.interests.removeAll { legacyInterests.contains($0.lowercased()) }
            changes += beforeInterests - person.interests.count

            let oldLines = person.personalityNotes.components(separatedBy: .newlines)
            let cleanedLines = oldLines.filter {
                let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !rawLines.contains(normalized) && !legacyPersonality.contains(normalized)
            }
            if cleanedLines != oldLines {
                person.personalityNotes = cleanedLines.joined(separator: "\n")
                changes += oldLines.count - cleanedLines.count
            }

            let importTimes = personImports.map(\.createdAt)
            func wasCreatedWithImport(_ date: Date) -> Bool {
                importTimes.contains { abs($0.timeIntervalSince(date)) < 600 }
            }

            for date in person.importantDates where date.sourceCaptureUUID == nil
                && date.title.caseInsensitiveCompare("Important date") == .orderedSame
                && wasCreatedWithImport(date.createdAt) {
                NotificationService.shared.cancel(importantDate: date)
                context.delete(date)
                changes += 1
            }
            for reminder in person.reminders where reminder.sourceCaptureUUID == nil
                && reminder.type == .followUp
                && wasCreatedWithImport(reminder.createdAt) {
                NotificationService.shared.cancel(reminder: reminder)
                context.delete(reminder)
                changes += 1
            }
            for gift in person.giftIdeas where gift.sourceCaptureUUID == nil
                && gift.notes.hasPrefix("From note on ")
                && wasCreatedWithImport(gift.createdAt) {
                context.delete(gift)
                changes += 1
            }
            person.recomputeContactDates()
        }

        if changes > 0 { try? context.save() }
        return changes
    }
}
