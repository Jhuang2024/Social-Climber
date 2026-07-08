import Foundation

/// Social Climber's side of the small App Group bridge with LockedInFit.
/// This is the only file that knows LockedInFit exists: the filenames, the
/// App Group identifier, and both Codable schemas live here (or in the two
/// context model files this reads/writes). Everywhere else in Social
/// Climber only ever sees plain values this manager hands back
/// (`SocialReadinessMode`, `LinkStatus`), never `LockedInFitPublicContext`
/// directly.
enum CrossAppIntegrationManager {
    /// Shared with LockedInFit; both apps' App Group entitlements must list
    /// this identifier for the bridge to activate.
    static let appGroupID = "group.com.jerry.personalOS"

    private static let outgoingFilename = "socialclimber_public_context_v1.json"
    private static let incomingFilename = "lockedinfit_public_context_v1.json"

    /// A snapshot older than this is treated as absent: showing nothing is
    /// safer than showing wrong context.
    private static let staleAfter: TimeInterval = 24 * 3600

    private static let sharingEnabledKey = "crossAppSharingEnabled"

    private static let locator: SharedContainerLocating = AppGroupContainerLocator(appGroupID: appGroupID)
    private static let store = SharedContextStore(locator: locator)

    /// The single flag that gates both publishing Social Climber's own
    /// snapshot and reading LockedInFit's. Defaults to on: the default is
    /// registered in `SocialClimberApp` so this reads consistently whether
    /// or not the Settings screen has ever been opened.
    static var isSharingEnabled: Bool {
        UserDefaults.standard.bool(forKey: sharingEnabledKey)
    }

    /// Whether the shared App Group container actually resolves on this
    /// build, independent of the sharing toggle: a signing/provisioning
    /// fact, not something the user can affect from Settings.
    static var isAppGroupAvailable: Bool {
        locator.containerURL() != nil
    }

    /// The Settings screen's live read on the bridge: whether a file from
    /// LockedInFit has ever been found, and if so, whether it's fresh
    /// enough to actually use.
    enum LinkStatus: Equatable {
        case notDetected
        case stale(updatedAt: Date)
        case linked(updatedAt: Date)
    }

    /// Decodes LockedInFit's file with no staleness filtering, so the
    /// Settings screen can tell "stale" apart from "never seen it." Still
    /// gated by `isSharingEnabled`: with sharing off, Social Climber
    /// doesn't even peek at the file.
    private static func decodedLockedInFitContext() -> LockedInFitPublicContext? {
        guard isSharingEnabled else { return nil }
        return store.read(LockedInFitPublicContext.self, from: incomingFilename, decode: LockedInFitPublicContext.decode)
    }

    /// LockedInFit's readiness context for today, or `nil` if sharing is
    /// off, the bridge is unavailable, the file is missing/corrupted, or
    /// the snapshot is older than 24 hours.
    static func lockedInFitContext(now: Date = .now) -> LockedInFitPublicContext? {
        guard let context = decodedLockedInFitContext() else { return nil }
        guard now.timeIntervalSince(context.updatedAt) <= staleAfter else { return nil }
        return context
    }

    /// For the Settings screen's Status section: whether a file was found
    /// at all, and if so, whether it's fresh enough to actually use.
    static func linkStatus(now: Date = .now) -> LinkStatus {
        guard let context = decodedLockedInFitContext() else { return .notDetected }
        if now.timeIntervalSince(context.updatedAt) <= staleAfter {
            return .linked(updatedAt: context.updatedAt)
        }
        return .stale(updatedAt: context.updatedAt)
    }

    /// `nil` when there's no usable readiness context to show at all (so
    /// the UI can skip the card entirely); otherwise whether today should
    /// look normal or quieted down, plus a one-line reason.
    static func readinessMode(now: Date = .now) -> SocialReadinessMode? {
        guard let today = lockedInFitContext(now: now)?.today else { return nil }
        if today.isLowReadiness {
            return .reduced(reason: today.readinessSummary)
        }
        return .normal(summary: today.readinessSummary)
    }

    /// Publishes Social Climber's own public context snapshot. A no-op when
    /// sharing is off or the App Group container is unavailable; otherwise
    /// safe to call often (e.g. whenever the dashboard loads), since it
    /// just overwrites the same file atomically each time.
    static func publish(
        reminders: [Reminder],
        events: [Event],
        pendingSharedImports: [SharedImportEntry] = SharedImportInbox.pending(),
        now: Date = .now
    ) {
        guard isSharingEnabled else { return }
        let snapshot = SocialClimberPublicContext.build(
            reminders: reminders,
            events: events,
            pendingSharedImports: pendingSharedImports,
            now: now
        )
        store.write(snapshot, to: outgoingFilename)
    }
}

/// How LockedInFit's readiness context should shape today's social noise.
/// Both cases carry a short, user-facing line for the dashboard's readiness
/// card; there's no case for "no data," since that's represented by
/// `CrossAppIntegrationManager.readinessMode()` returning `nil`.
enum SocialReadinessMode: Equatable {
    case normal(summary: String)
    case reduced(reason: String)

    var summary: String {
        switch self {
        case .normal(let summary): summary
        case .reduced(let reason): reason
        }
    }

    var isReduced: Bool {
        if case .reduced = self { return true }
        return false
    }
}
