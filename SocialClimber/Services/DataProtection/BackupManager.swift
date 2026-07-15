import Foundation
import SwiftData

/// Automatic and manual JSON backup snapshots, kept in their own directory,
/// clearly separate from SwiftData's live store. A backup is exactly the
/// same archive format "Export JSON…" already produces
/// (`ExportImportService.Archive`), so restoring one is always a
/// merge-import: it can only add or update records by name, never delete or
/// replace what's already in the live database. That's what makes it safe
/// to restore an empty or partial backup without ever risking the active
/// data.
///
/// Every backup is written twice: once into this app's own sandbox (fast,
/// private, but wiped along with the sandbox when a reinstall or a
/// signing/entitlement change replaces the app container) and once, mirrored,
/// into the shared App Group container, which has its own lifecycle and
/// survives app updates and reinstalls. The mirror is exactly the same
/// reinstall-surviving safety net LockedInFit and Brief already keep: a
/// "latest" copy that always tracks the newest backup, and a "best" copy that
/// only ever advances to a snapshot with at least as many records, so a
/// post-wipe rebuild of nearly-empty data can never overwrite the most
/// complete copy the family still has.
enum BackupManager {
    struct BackupInfo: Identifiable, Equatable {
        /// Where this backup physically lives.
        enum Location: Equatable {
            /// `Application Support/Backups` inside this app's sandbox: fast
            /// and private, but dies with the sandbox when a reinstall or a
            /// signing change makes an update replace the app container.
            case local
            /// The shared App Group container, which has its own lifecycle
            /// and survives app updates and reinstalls. See the mirror
            /// functions below.
            case sharedContainer
        }

        let url: URL
        let createdAt: Date
        let reason: String
        /// Records the backup holds, when known. `nil` for a local backup
        /// listed cheaply by `listBackups()` (which never decodes contents);
        /// always set for App Group mirrors (read from their sidecar meta)
        /// and for every entry `allKnownBackups()` returns.
        var recordCount: Int? = nil
        var location: Location = .local
        var id: URL { url }
    }

    /// Keep only the most recent local backups; older ones are deleted on
    /// rotation. The App Group mirror keeps its own "latest"/"best" pair and
    /// is unaffected by local rotation.
    private static let maxBackupsKept = 5

    /// `Application Support/Backups`, a sibling of (never inside) wherever
    /// SwiftData's live store lives, so a bug in one can't touch the other.
    static var backupsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The App Group mirror directory, or `nil` when the shared container
    /// isn't provisioned for this build. `SocialClimberBackups` is this app's
    /// own subfolder of the shared container, kept distinct from the folders
    /// LockedInFit and Brief mirror into so the three apps never overwrite
    /// each other's backups.
    private static var appGroupBackupsDirectory: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CrossAppIntegrationManager.appGroupID
        ) else { return nil }
        let dir = container.appendingPathComponent("SocialClimberBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Writes a new backup (locally, then mirrored to the App Group) and
    /// rotates old local ones away. `reason` is a short, filename-safe tag
    /// ("manual," "schema-migration") shown back to the user in the restore
    /// list. Returns `nil` (silently) if the export or write fails; a failed
    /// backup attempt should never crash or block app launch.
    @discardableResult
    static func createBackup(context: ModelContext, reason: String) -> BackupInfo? {
        guard let data = try? ExportImportService.exportData(context: context) else { return nil }
        let now = Date.now
        let safeTimestamp = timestampFormatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = backupsDirectory.appendingPathComponent("\(safeTimestamp)_\(reason).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        rotate()
        let recordCount = ExportImportService.recordCount(in: data)
        mirrorToAppGroup(data: data, date: now, recordCount: recordCount ?? 0)
        return BackupInfo(url: url, createdAt: now, reason: reason, recordCount: recordCount)
    }

    /// The local backups only, newest first. Cheap: reads the directory and
    /// filenames without decoding any backup's contents, so `recordCount`
    /// stays `nil`. Use `allKnownBackups()` when completeness matters.
    static func listBackups() -> [BackupInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> BackupInfo? in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let reason = url.deletingPathExtension().lastPathComponent
                    .split(separator: "_", maxSplits: 1)
                    .last.map(String.init) ?? "backup"
                return BackupInfo(url: url, createdAt: date, reason: reason)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Every backup this device can still see: the local rotation plus the
    /// App Group mirrors that outlive a reinstall, ranked most-complete first
    /// (then newest first). The single source of truth for "the best backup
    /// we have" — after a reinstall wipes the sandbox the local list is empty
    /// and only the mirrors remain, and after an in-app wipe the newest local
    /// backup is of the nearly-empty post-wipe state, so completeness, not
    /// recency, is what should lead. Decodes the (at most five) local files to
    /// learn their record counts, so call it from restore/recovery surfaces,
    /// not the hot backup-writing path.
    static func allKnownBackups() -> [BackupInfo] {
        let locals = listBackups().map { info -> BackupInfo in
            var info = info
            info.recordCount = recordCount(at: info.url)
            return info
        }
        return (locals + appGroupMirrorBackups()).sorted {
            let left = $0.recordCount ?? -1
            let right = $1.recordCount ?? -1
            if left != right { return left > right }
            return $0.createdAt > $1.createdAt
        }
    }

    /// The most complete backup known anywhere (local or shared container).
    static func mostCompleteBackup() -> BackupInfo? { allKnownBackups().first }

    static func latestBackupTimestamp() -> Date? {
        listBackups().first?.createdAt
    }

    private static func recordCount(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ExportImportService.recordCount(in: data)
    }

    private static func rotate() {
        let backups = listBackups()
        guard backups.count > maxBackupsKept else { return }
        for stale in backups.dropFirst(maxBackupsKept) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    // MARK: - App Group mirrors (survive app updates/reinstalls)

    /// The tiny record kept alongside each mirror snapshot so listing one
    /// never has to decode the full archive just to read its date and count.
    private struct MirrorMeta: Codable {
        var date: Date
        var recordCount: Int
    }

    /// Mirrors a just-written backup into the shared container: "latest"
    /// always tracks the newest backup, "best" only ever advances to a
    /// backup with at least as many records. An empty snapshot never
    /// overwrites mirrors that already hold real data (an in-app "clear all"
    /// or a transient empty read must not wipe the reinstall-surviving copy),
    /// matching the empty-backup guard the other apps apply before mirroring.
    private static func mirrorToAppGroup(data: Data, date: Date, recordCount: Int) {
        guard let dir = appGroupBackupsDirectory else { return }
        if recordCount == 0 {
            let existingBest = mirrorMeta(named: "backup-best", in: dir)?.recordCount ?? 0
            let existingLatest = mirrorMeta(named: "backup-latest", in: dir)?.recordCount ?? 0
            if existingBest > 0 || existingLatest > 0 { return }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let meta = try? encoder.encode(MirrorMeta(date: date, recordCount: recordCount)) else { return }

        writeMirror(named: "backup-latest", data: data, meta: meta, in: dir)

        let bestCount = mirrorMeta(named: "backup-best", in: dir)?.recordCount ?? -1
        if recordCount >= bestCount {
            writeMirror(named: "backup-best", data: data, meta: meta, in: dir)
        }
    }

    private static func mirrorMeta(named name: String, in dir: URL) -> MirrorMeta? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name + ".meta.json")) else { return nil }
        return try? decoder.decode(MirrorMeta.self, from: data)
    }

    private static func writeMirror(named name: String, data: Data, meta: Data, in dir: URL) {
        try? data.write(to: dir.appendingPathComponent(name + ".json"), options: .atomic)
        try? meta.write(to: dir.appendingPathComponent(name + ".meta.json"), options: .atomic)
    }

    /// The App Group mirror backups, for the restore picker. Empty when the
    /// shared container is unavailable or no mirror has been written yet.
    static func appGroupMirrorBackups() -> [BackupInfo] {
        guard let dir = appGroupBackupsDirectory else { return [] }
        var output: [BackupInfo] = []
        for name in ["backup-best", "backup-latest"] {
            let file = dir.appendingPathComponent(name + ".json")
            guard FileManager.default.fileExists(atPath: file.path),
                  let meta = mirrorMeta(named: name, in: dir) else { continue }
            let reason = (name == "backup-best") ? "most-complete" : "latest"
            output.append(BackupInfo(url: file, createdAt: meta.date, reason: reason,
                                     recordCount: meta.recordCount, location: .sharedContainer))
        }
        // best and latest are often the same snapshot; no point listing twice.
        if output.count == 2, output[0].createdAt == output[1].createdAt, output[0].recordCount == output[1].recordCount {
            output.removeLast()
        }
        return output
    }
}
