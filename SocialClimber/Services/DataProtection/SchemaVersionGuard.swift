import Foundation
import SwiftData

/// Detects a schema/model shape change between launches and takes one
/// automatic backup snapshot the first time it's seen, so any migration,
/// even a routine additive one, always leaves a rollback point behind.
///
/// True "before the migration touches anything" snapshotting would need
/// SwiftData's `VersionedSchema`/`SchemaMigrationPlan` machinery layered
/// onto every `@Model` type, a much larger change than this pass makes.
/// Instead, this snapshots immediately after `ModelContainer` finishes
/// opening (and SwiftData's own lightweight migration completes), which is
/// as early as a plain `ModelContainer(for:)` call allows. Paired with
/// `DataLossGuard`'s zero-record check on the very next launch, a migration
/// that unexpectedly wiped data still gets caught.
enum SchemaVersionGuard {
    /// Bump this whenever a `@Model` class's stored properties change
    /// shape (a field added, removed, or retyped).
    static let currentSchemaVersion = 1

    private static let key = "lastKnownSchemaVersion"

    static func backupIfNeeded(container: ModelContainer) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key) as? Int
        defaults.set(currentSchemaVersion, forKey: key)
        guard previous != currentSchemaVersion else { return }
        let context = ModelContext(container)
        BackupManager.createBackup(context: context, reason: "schema-migration")
    }
}
