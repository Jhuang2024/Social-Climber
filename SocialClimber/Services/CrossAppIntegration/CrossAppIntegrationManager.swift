import Foundation

/// Abstracts how Social Climber exchanges its public context snapshot with
/// Locked In Fit, so the rest of the app never has to know whether an App
/// Group container is actually available. `CrossAppIntegrationManager`
/// picks `AppGroupCrossAppBridge` when the shared container is reachable
/// and `NoOpCrossAppBridge` otherwise — every call on either one is safe to
/// make unconditionally.
protocol CrossAppContextBridge {
    func readLockedInFitContext() -> LockedInFitPublicContext?
    func publish(_ context: SocialClimberPublicContext)
}

/// Reads/writes versioned JSON files in the shared App Group container.
/// Nothing here touches Locked In Fit's actual database: this only ever
/// sees whatever small public snapshot it chooses to publish to the same
/// container.
struct AppGroupCrossAppBridge: CrossAppContextBridge {
    let containerURL: URL

    /// Named after the app that publishes it, not the app that reads it,
    /// so both sides' file names stay obvious from either codebase.
    private static let incomingFileName = "LockedInFitPublicContext.json"
    private static let outgoingFileName = "SocialClimberPublicContext.json"

    func readLockedInFitContext() -> LockedInFitPublicContext? {
        let url = containerURL.appendingPathComponent(Self.incomingFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return LockedInFitPublicContext.decode(from: data)
    }

    /// Atomic write so a reader never sees a half-written file.
    func publish(_ context: SocialClimberPublicContext) {
        guard let data = context.encoded() else { return }
        let url = containerURL.appendingPathComponent(Self.outgoingFileName)
        try? data.write(to: url, options: .atomic)
    }
}

/// Used whenever the shared App Group container isn't reachable (App Groups
/// not configured in this build/signing setup, or the entitlement missing).
/// Every call is a no-op, so Social Climber behaves exactly as it does
/// without the integration.
struct NoOpCrossAppBridge: CrossAppContextBridge {
    func readLockedInFitContext() -> LockedInFitPublicContext? { nil }
    func publish(_ context: SocialClimberPublicContext) {}
}

/// How Locked In Fit's readiness context should shape today's social noise.
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

/// The single entry point the rest of Social Climber uses for the Locked In
/// Fit bridge: reading readiness context and publishing Social Climber's own
/// snapshot. Everything is optional and fails soft — a missing, stale, or
/// corrupted file is treated identically to "Locked In Fit isn't installed."
enum CrossAppIntegrationManager {
    /// Shared with Locked In Fit; both apps' App Group entitlements must
    /// list this identifier for the bridge to activate.
    static let appGroupID = "group.com.jerryhuang.personalOS"

    /// Readiness context older than this is ignored for prioritization:
    /// showing nothing is safer than showing wrong context.
    private static let staleAfter: TimeInterval = 24 * 3600

    private static let bridge: CrossAppContextBridge = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return AppGroupCrossAppBridge(containerURL: url)
        }
        return NoOpCrossAppBridge()
    }()

    /// Locked In Fit's readiness context for today, or `nil` if the bridge
    /// is unavailable, the file is missing/corrupted, or the snapshot is
    /// older than 24 hours.
    static func lockedInFitContext(now: Date = .now) -> LockedInFitPublicContext? {
        guard let context = bridge.readLockedInFitContext() else { return nil }
        guard now.timeIntervalSince(context.updatedAt) <= staleAfter else { return nil }
        return context
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

    /// Publishes Social Climber's own public context snapshot. Safe to call
    /// often (e.g. whenever the dashboard loads): a no-op bridge just drops
    /// it, and a real one overwrites the same file atomically.
    static func publish(
        reminders: [Reminder],
        events: [Event],
        pendingSharedImports: [SharedImportEntry] = SharedImportInbox.pending()
    ) {
        let snapshot = SocialClimberPublicContext.build(
            reminders: reminders,
            events: events,
            pendingSharedImports: pendingSharedImports
        )
        bridge.publish(snapshot)
    }
}
