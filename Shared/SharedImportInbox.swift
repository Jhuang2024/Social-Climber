import Foundation

/// One payload handed to Social Climber from the Share Extension: plain
/// text (selected Messages bubbles, a paragraph from anywhere) and/or
/// image files (screenshots), waiting to be imported as a capture the next
/// time the app runs. The main app turns each entry into a durable
/// `CapturedMemory` and processes it automatically; the user is never told
/// to "open the app to finish logging".
struct SharedImportEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    /// File names inside `SharedImportInbox.imagesDirectory` (App Group).
    var imageFileNames: [String]
    /// Bundle identifier of the app the content was shared from, when the
    /// extension could determine it. Purely informational.
    var sourceApp: String
    let receivedAt: Date

    init(id: UUID = UUID(), text: String, imageFileNames: [String] = [], sourceApp: String = "", receivedAt: Date = .now) {
        self.id = id
        self.text = text
        self.imageFileNames = imageFileNames
        self.sourceApp = sourceApp
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, imageFileNames, sourceApp, receivedAt
    }

    /// Entries queued by an older extension build (text-only) decode with
    /// the newer fields defaulted, so an update never strands the queue.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        imageFileNames = (try? c.decodeIfPresent([String].self, forKey: .imageFileNames)) ?? []
        sourceApp = (try? c.decodeIfPresent(String.self, forKey: .sourceApp)) ?? ""
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
    }
}

/// A small App Group-backed queue that lets the Share Extension hand
/// content off to the main app without either side needing to be running at
/// the same time. Both the extension and the app target compile this same
/// file, sharing one App Group-scoped `UserDefaults` suite guarded by the
/// App Group entitlement declared on both targets. Nothing here touches
/// the network; it's purely on-device, inter-process handoff. The queue
/// survives app and extension crashes: entries are only removed once the
/// main app has durably persisted them.
enum SharedImportInbox {
    private static let appGroupID = "group.com.jerryhuang.SocialClimber"
    private static let storageKey = "pendingSharedImports"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Where shared images are staged inside the App Group container until
    /// the main app copies them into its own sandbox.
    static var imagesDirectory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        let dir = base.appendingPathComponent("SharedImportImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Called by the Share Extension. Appends rather than replaces, so
    /// sharing several snippets before opening the app queues all of them.
    static func add(_ entry: SharedImportEntry) {
        let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !entry.imageFileNames.isEmpty, let defaults else { return }
        var entries = pending()
        entries.append(entry)
        save(entries, to: defaults)
    }

    /// Text-only convenience, kept for the plain-text share path.
    static func add(_ text: String) {
        add(SharedImportEntry(text: text))
    }

    /// Called by the main app to see what's waiting to be imported.
    static func pending() -> [SharedImportEntry] {
        guard let defaults, let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([SharedImportEntry].self, from: data)) ?? []
    }

    /// Removes a single entry once the app has durably persisted it as a
    /// capture. `deletingImages` also cleans up its staged image files:
    /// pass true only after they've been copied out of the App Group.
    static func remove(_ id: UUID, deletingImages: Bool = false) {
        guard let defaults else { return }
        let entries = pending()
        if deletingImages, let entry = entries.first(where: { $0.id == id }), let dir = imagesDirectory {
            for name in entry.imageFileNames {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        save(entries.filter { $0.id != id }, to: defaults)
    }

    private static func save(_ entries: [SharedImportEntry], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
