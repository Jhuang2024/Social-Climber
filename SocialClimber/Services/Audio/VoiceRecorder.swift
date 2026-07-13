import Foundation
import AVFoundation
import UIKit

/// The shared voice recorder. Wraps `AVAudioRecorder` behind the
/// `AudioCaptureState` machine and handles everything that makes recording
/// survive real-world conditions:
///   • speech-tuned settings and the clearest input route,
///   • interruption recovery (phone calls, Siri, other audio apps),
///   • backgrounding/loss-of-focus without losing what was captured,
///   • progressive, segmented saving so a crash costs at most the current
///     segment, and the original audio is always preserved on disk.
///
/// UI never talks to `AVAudioRecorder` directly; it observes `state`,
/// `level`, and `duration` and calls `start/pause/resume/stop`.
@MainActor
final class VoiceRecorder: NSObject {

    /// Current lifecycle state, driven through the pure state machine.
    private(set) var state: AudioCaptureState = .idle
    /// 0...1 normalised input level for a live meter.
    private(set) var level: Float = 0
    /// Elapsed capture time across all segments, seconds.
    private(set) var duration: TimeInterval = 0
    /// Set when `state == .failed`.
    private(set) var failure: AudioCaptureFailure?

    /// Called on the main actor after any observable change (state, level,
    /// duration), so an `@Observable` owner can mirror values into its own
    /// tracked properties and drive SwiftUI updates.
    var onChange: (() -> Void)?

    /// Finalised segment file names (inside `VoiceNote.directory`), in order.
    /// Multiple entries appear when interruptions/backgrounding chopped the
    /// capture into crash-safe pieces; they're merged on `finish()`.
    private(set) var segmentFileNames: [String] = []

    private var machine = AudioCaptureStateMachine()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentSegmentStartDuration: TimeInterval = 0
    /// True while an interruption/backgrounding is in effect and we intend to
    /// auto-resume when it clears (only when the user hadn't manually paused).
    private var resumeAfterInterruption = false

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appWillResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        meterTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: State plumbing

    private func setState(_ next: AudioCaptureState, failure: AudioCaptureFailure? = nil) {
        guard machine.transition(to: next) else {
            AudioLog.warn("Rejected illegal recorder transition \(state.rawValue) → \(next.rawValue)")
            return
        }
        state = machine.state
        self.failure = next == .failed ? (failure ?? .unknown) : nil
        AudioLog.debug("Recorder state → \(next.rawValue)")
        onChange?()
    }

    // MARK: Public controls

    /// Requests mic permission (if needed) and starts a fresh capture.
    func start() async {
        guard state == .idle || state.isTerminal else { return }
        let granted = await Self.requestMicrophonePermission()
        guard granted else {
            reset()
            setState(.failed, failure: .microphonePermissionDenied)
            return
        }
        reset()
        AudioSessionManager.shared.handler = self
        do {
            try AudioSessionManager.shared.activateForRecording()
        } catch {
            setState(.failed, failure: .audioSessionUnavailable)
            return
        }
        if beginSegment() {
            setState(.recording)
            startMetering()
        } else {
            setState(.failed, failure: .recordingFailed)
        }
    }

    /// User-initiated pause. Finalises the current segment so it's safe on disk.
    func pause() {
        guard state == .recording else { return }
        resumeAfterInterruption = false
        finalizeSegment()
        setState(.paused)
        stopMetering()
    }

    /// Resume after a user pause by opening a new segment.
    func resume() {
        guard state == .paused else { return }
        if beginSegment() {
            setState(.recording)
            startMetering()
        } else {
            setState(.failed, failure: .recordingFailed)
        }
    }

    /// Stops the capture and hands back a single merged audio file name (the
    /// preserved original). Returns `nil` only if nothing was captured.
    /// Leaves the recorder in `.processing`; the caller drives it to
    /// `.completed`/`.failed` via `markProcessed`.
    func stop() async -> String? {
        guard state == .recording || state == .paused || state == .interrupted else { return nil }
        finalizeSegment()
        stopMetering()
        level = 0
        AudioSessionManager.shared.deactivate()
        AudioSessionManager.shared.handler = nil
        setState(.processing)

        let names = segmentFileNames
        guard !names.isEmpty else { return nil }
        if names.count == 1 { return names[0] }
        // Merge crash-safe segments into one canonical original recording.
        return await AudioFileMerger.merge(segmentFileNames: names)
    }

    /// Reports the pipeline outcome so the recorder can settle in a terminal
    /// state the UI can render.
    func markProcessed(success: Bool, failure: AudioCaptureFailure? = nil) {
        setState(success ? .completed : .failed, failure: failure)
    }

    /// Discards everything captured and returns to idle; used on Cancel.
    func discard() {
        finalizeSegment()
        stopMetering()
        AudioSessionManager.shared.deactivate()
        AudioSessionManager.shared.handler = nil
        for name in segmentFileNames {
            try? FileManager.default.removeItem(at: VoiceNote.directory.appendingPathComponent(name))
        }
        reset()
    }

    private func reset() {
        recorder?.stop()
        recorder = nil
        segmentFileNames = []
        duration = 0
        currentSegmentStartDuration = 0
        level = 0
        failure = nil
        resumeAfterInterruption = false
        machine = AudioCaptureStateMachine()
        state = .idle
        onChange?()
    }

    // MARK: Segment recording

    /// Opens a new segment file and starts recording into it. Each segment is a
    /// complete, finalisable .m4a, so an app kill loses at most the open one.
    @discardableResult
    private func beginSegment() -> Bool {
        let fileName = "\(UUID().uuidString).m4a"
        let url = VoiceNote.directory.appendingPathComponent(fileName)
        do {
            let recorder = try AVAudioRecorder(url: url, settings: SpeechAudioFormat.recorderSettings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }
            self.recorder = recorder
            segmentFileNames.append(fileName)
            currentSegmentStartDuration = duration
            return true
        } catch {
            AudioLog.error("Failed to open recording segment: \(error.localizedDescription)")
            return false
        }
    }

    /// Stops and finalises the current segment, folding its length into the
    /// running total. Idempotent.
    private func finalizeSegment() {
        guard let recorder else { return }
        duration = currentSegmentStartDuration + recorder.currentTime
        recorder.stop()
        self.recorder = nil
        // Drop a segment that captured nothing so empty files don't pollute the
        // merge.
        if let last = segmentFileNames.last {
            let url = VoiceNote.directory.appendingPathComponent(last)
            if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 1024 {
                try? FileManager.default.removeItem(at: url)
                segmentFileNames.removeLast()
            }
        }
    }

    // MARK: Metering

    private func startMetering() {
        stopMetering()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // Map -60...0 dBFS onto 0...1 for the meter.
        let power = recorder.averagePower(forChannel: 0)
        let clamped = max(-60, min(0, power))
        level = (clamped + 60) / 60
        duration = currentSegmentStartDuration + recorder.currentTime
        onChange?()
    }

    // MARK: Permission

    static func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: Backgrounding

    @objc private func appWillResignActive() {
        guard state == .recording else { return }
        // Preserve what we have synchronously (before the app suspends) and
        // mark interrupted; auto-resume when we return unless the user chose
        // otherwise.
        resumeAfterInterruption = true
        finalizeSegment()
        stopMetering()
        setState(.interrupted)
    }

    @objc private func appDidBecomeActive() {
        Task { @MainActor in
            guard state == .interrupted, resumeAfterInterruption else { return }
            try? AudioSessionManager.shared.reactivateAfterInterruption()
            if beginSegment() {
                setState(.recording)
                startMetering()
            }
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension VoiceRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            AudioLog.error("Recorder encode error: \(error?.localizedDescription ?? "unknown")")
            // A finalised prior segment is still safe; only fail if we have
            // nothing at all.
            if segmentFileNames.isEmpty {
                setState(.failed, failure: .recordingFailed)
            }
        }
    }
}

// MARK: - AudioSessionEventHandler

extension VoiceRecorder: AudioSessionEventHandler {
    func audioSessionDidBeginInterruption() {
        guard state == .recording else { return }
        resumeAfterInterruption = true
        finalizeSegment()
        stopMetering()
        setState(.interrupted)
    }

    func audioSessionDidEndInterruption(shouldResume: Bool) {
        guard state == .interrupted, resumeAfterInterruption, shouldResume else { return }
        try? AudioSessionManager.shared.reactivateAfterInterruption()
        if beginSegment() {
            setState(.recording)
            startMetering()
        }
    }

    func audioSessionRouteDidChange(reason: AVAudioSession.RouteChangeReason) {
        // We deliberately do NOT re-select the input mid-recording; that would
        // be the "unexpected route switch" the requirements forbid. We only log
        // the change; the pinned preferred input keeps the route stable.
        AudioLog.debug("Route changed (reason \(reason.rawValue)) while state=\(state.rawValue)")
    }

    func audioSessionMediaServicesWereReset() {
        // The session died out from under us. Preserve captured segments and
        // surface an interrupted state the user can resume from.
        guard state == .recording else { return }
        resumeAfterInterruption = false
        finalizeSegment()
        stopMetering()
        setState(.interrupted)
    }
}
