import Foundation

/// The lifecycle of a single audio capture, from tapping record through to a
/// finished (or failed) transcript. Kept as a small, pure state machine so the
/// UI can render an honest status for every stage and so the transition rules
/// can be unit-tested without any AVFoundation or SwiftData involvement.
///
/// This is the single source of truth the whole shared pipeline reports
/// against — `VoiceRecorder`, `RecordingProcessor`, and the capture screens all
/// speak in these states rather than inventing their own booleans.
enum AudioCaptureState: String, Codable, CaseIterable, Sendable {
    /// Nothing captured yet.
    case idle
    /// Actively writing audio to disk.
    case recording
    /// User-initiated pause; the file is intact and recording can resume.
    case paused
    /// System-initiated pause (phone call, Siri, another app taking the
    /// session). Distinct from `.paused` so the UI can explain *why* and so
    /// recovery can auto-resume when the interruption ends.
    case interrupted
    /// Audio is captured and the enhancement/transcription pipeline is running.
    case processing
    /// Transcript is ready.
    case completed
    /// Something went wrong; `AudioCaptureFailure` carries the reason and the
    /// capture can be retried.
    case failed

    /// True while audio is being written to disk in some form.
    var isActivelyCapturing: Bool { self == .recording }

    /// True when the capture is in a stable resting state the user can act on
    /// (retry, review, discard) rather than a transient one.
    var isTerminal: Bool { self == .completed || self == .failed }

    /// User-facing label, deliberately plain so it reads well on a button or
    /// status line.
    var label: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

/// Why a capture could not be completed. Surfaced to the user as an actionable
/// message and stored on the `VoiceNote` so a failed capture is never silently
/// dropped — every one of these is retryable.
enum AudioCaptureFailure: String, Codable, CaseIterable, Sendable {
    case microphonePermissionDenied
    case audioSessionUnavailable
    case recordingFailed
    case noSpeechDetected
    case recordingTooQuiet
    case excessiveBackgroundNoise
    case transcriptionUnavailable
    case partialTranscription
    case unknown

    /// A concise, non-technical explanation. Never contains transcript text.
    var message: String {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is off. You can type the note instead, or enable the mic in Settings."
        case .audioSessionUnavailable:
            return "The audio system was busy. Try recording again in a moment."
        case .recordingFailed:
            return "Recording couldn't be saved. Please try again."
        case .noSpeechDetected:
            return "No speech was detected in this recording."
        case .recordingTooQuiet:
            return "The recording was too quiet to transcribe reliably. You can retry, or type the note."
        case .excessiveBackgroundNoise:
            return "There was too much background noise to transcribe clearly. Retry in a quieter spot, or type the note."
        case .transcriptionUnavailable:
            return "On-device transcription isn't available right now. The audio is saved — you can retry, or type the note."
        case .partialTranscription:
            return "Only part of the recording could be transcribed. Review the text, then retry the rest if you like."
        case .unknown:
            return "Something went wrong while processing this recording. The audio is saved — you can retry."
        }
    }

    /// Whether the captured audio is still worth keeping and retrying. Every
    /// current case is retryable (the original audio is always preserved);
    /// this exists so future non-retryable cases have a clear home.
    var isRetryable: Bool { true }
}

/// A tiny, pure transition table for `AudioCaptureState`. Centralising the
/// legal moves here means the recorder and processor can't drift into
/// inconsistent states, and the rules are trivially testable.
struct AudioCaptureStateMachine {
    private(set) var state: AudioCaptureState

    init(state: AudioCaptureState = .idle) {
        self.state = state
    }

    /// The set of states reachable in one step from `from`.
    static func allowedTransitions(from: AudioCaptureState) -> Set<AudioCaptureState> {
        switch from {
        case .idle:
            return [.recording]
        case .recording:
            return [.paused, .interrupted, .processing, .failed]
        case .paused:
            // Resume, stop-and-process, or an interruption arriving while paused.
            return [.recording, .interrupted, .processing, .failed]
        case .interrupted:
            // Auto-resume when the interruption ends, stop-and-process, or give up.
            return [.recording, .paused, .processing, .failed]
        case .processing:
            return [.completed, .failed]
        case .completed:
            // Re-run transcription/enhancement on an already-finished capture.
            return [.processing]
        case .failed:
            // Retry from a failure.
            return [.processing, .recording]
        }
    }

    func canTransition(to next: AudioCaptureState) -> Bool {
        next == state || Self.allowedTransitions(from: state).contains(next)
    }

    /// Attempts a transition. Returns `false` (and leaves `state` unchanged)
    /// when the move is illegal, so callers can assert on invariants rather
    /// than silently corrupting state. A no-op transition to the current state
    /// is always allowed.
    @discardableResult
    mutating func transition(to next: AudioCaptureState) -> Bool {
        guard canTransition(to: next) else { return false }
        state = next
        return true
    }
}
