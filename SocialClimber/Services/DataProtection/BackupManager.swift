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
enum BackupManager {
    struct BackupInfo: Identifiable, Equatable {
        let url: URL
        let createdAt: Date
        let reason: String
        var id: URL { url }
    }

    /// Keep only the most recent backups; older ones are deleted on rotation.
    private static let maxBackupsKept = 5

    /// `Application Support/Backups`, a sibling of (never inside) wherever
    /// SwiftData's live store lives, so a bug in one can't touch the other.
    static var backupsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Writes a new backup and rotates old ones away. `reason` is a short,
    /// filename-safe tag ("manual," "schema-migration") shown back to the
    /// user in the restore list. Returns `nil` (silently) if the export or
    /// write fails; a failed backup attempt should never crash or block
    /// app launch.
    @discardableResult
    static func createBackup(context: ModelContext, reason: String) -> BackupInfo? {
        guard let data = try? ExportImportService.exportData(context: context) else { return nil }
        let now = Date.now
        let safeTimestamp = timestampFormatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = backupsDirectory.appendingPathComponent("\(safeTimestamp)_\(reason).json")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        rotate()
        return BackupInfo(url: url, createdAt: now, reason: reason)
    }

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

    static func latestBackupTimestamp() -> Date? {
        listBackups().first?.createdAt
    }

    private static func rotate() {
        let backups = listBackups()
        guard backups.count > maxBackupsKept else { return }
        for stale in backups.dropFirst(maxBackupsKept) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }
}
