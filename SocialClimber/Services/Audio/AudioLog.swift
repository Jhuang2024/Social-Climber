import Foundation
import OSLog

/// Structured logging for the audio/transcription pipeline that is useful in
/// development but never leaks private content.
///
/// The cardinal rule: **transcript text, note bodies, and contact names are
/// never passed to these functions.** Log durations, counts, states, error
/// descriptions, and route types: never what was said. Callers that need to
/// reference content should log a length or a redacted marker instead.
enum AudioLog {
    private static let logger = Logger(subsystem: "com.jerryhuang.SocialClimber", category: "audio")

    static func debug(_ message: String) {
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Convenience for logging that some text was processed without logging the
    /// text; reports only its character count.
    static func redactedLength(_ label: String, _ text: String) {
        debug("\(label): \(text.count) chars")
    }
}
