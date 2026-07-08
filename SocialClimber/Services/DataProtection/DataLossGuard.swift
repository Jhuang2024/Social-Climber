import Foundation

/// Detects the exact failure mode that prompted this whole safety net: the
/// app launching normally but its data having silently vanished (e.g. a
/// reinstall triggered by a signing/entitlement change wiping the app's
/// sandbox). The baseline lives in `KeychainService`, not `UserDefaults` or
/// a file, specifically so it survives that scenario.
enum DataLossGuard {
    /// `nil` when nothing looks wrong; otherwise the record count Social
    /// Climber remembers having before, for the recovery screen to show.
    static func checkForSuddenLoss(currentCount: Int) -> Int? {
        guard let previous = KeychainService.lastKnownRecordCount(), previous > 0, currentCount == 0 else {
            return nil
        }
        return previous
    }

    /// Called once the app has confirmed its current state is trustworthy:
    /// a normal launch with no alarm, a successful restore, or the user
    /// explicitly confirming "this is really empty now."
    static func recordCurrentCount(_ count: Int) {
        KeychainService.setLastKnownRecordCount(count)
    }
}
