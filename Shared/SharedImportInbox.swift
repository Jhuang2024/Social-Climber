import Foundation

/// A single piece of text handed to Social Climber from the Share
/// Extension (e.g. selected iMessage/SMS bubbles shared via the system
/// share sheet), waiting to be reviewed and logged as an interaction.
struct SharedImportEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let receivedAt: Date

    init(id: UUID = UUID(), text: String, receivedAt: Date = .now) {
        self.id = id
        self.text = text
        self.receivedAt = receivedAt
    }
}

/// A small App Group-backed queue that lets the Share Extension hand text
/// off to the main app without either side needing to be running at the
/// same time. Both the extension and the app target compile this same
/// file, sharing one App Group-scoped `UserDefaults` suite guarded by the
/// App Group entitlement declared on both targets. Nothing here touches
/// the network — it's purely on-device, inter-process handoff.
enum SharedImportInbox {
    private static let appGroupID = "group.com.jerryhuang.SocialClimber"
    private static let storageKey = "pendingSharedImports"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Called by the Share Extension when the user shares text into Social
    /// Climber. Appends rather than replaces, so sharing several snippets
    /// before opening the app queues all of them.
    static func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let defaults else { return }
        var entries = pending()
        entries.append(SharedImportEntry(text: trimmed))
        save(entries, to: defaults)
    }

    /// Called by the main app to see what's waiting to be reviewed.
    static func pending() -> [SharedImportEntry] {
        guard let defaults, let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([SharedImportEntry].self, from: data)) ?? []
    }

    /// Removes a single entry once the app has turned it into an
    /// interaction (or the user dismissed it).
    static func remove(_ id: UUID) {
        guard let defaults else { return }
        let remaining = pending().filter { $0.id != id }
        save(remaining, to: defaults)
    }

    private static func save(_ entries: [SharedImportEntry], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
