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

    /// Called on the main actor each time a segment is finalised and safe on
    /// disk (either by the 30-second rolling rotation or by `stop`), with that
    /// segment's file name inside `VoiceNote.directory`. The owner uses this to
    /// transcribe/parse the just-finished slice *while recording continues*, so
    /// a long conversation is processed piece-by-piece instead of in one slow
    /// pass at the end. Each segment is reported exactly once.
    var onSegmentFinalized: ((String) -> Void)?

    /// How long a single rolling segment runs before it's finalised (and handed
    /// off for background processing) and a fresh one is opened automatically.
    /// A two-minute conversation becomes four ~30s slices, each parsed as soon
    /// as it closes rather than all at once on stop.
    static let rollingSegmentDuration: TimeInterval = 30

    /// Finalised segment file names (inside `VoiceNote.directory`), in order.
    /// Multiple entries appear when the 30-second rolling rotation, or an
    /// interruption/backgrounding, chopped the capture into pieces; they're
    /// merged into one canonical original on stop.
    private(set) var segmentFileNames: [String] = []
    /// Segments already reported through `onSegmentFinalized`, so a segment is
    /// never handed off for processing twice.
    private var emittedSegmentNames: Set<String> = []

    private var machine = AudioCaptureStateMachine()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    /// Fires every `rollingSegmentDuration` while recording to rotate segments.
    private var rotationTimer: Timer?
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
        rotationTimer?.invalidate()
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
            startRotationTimer()
        } else {
            setState(.failed, failure: .recordingFailed)
        }
    }

    /// User-initiated pause. Finalises the current segment so it's safe on disk.
    func pause() {
        guard state == .recording else { return }
        resumeAfterInterruption = false
        stopRotationTimer()
        finalizeSegment()
        emitFinalizedSegment()
        setState(.paused)
        stopMetering()
    }

    /// Resume after a user pause by opening a new segment.
    func resume() {
        guard state == .paused else { return }
        if beginSegment() {
            setState(.recording)
            startMetering()
            startRotationTimer()
        } else {
            setState(.failed, failure: .recordingFailed)
        }
    }

    /// Ends the capture and returns the finalised segment file names *without
    /// merging yet*. The final still-open segment is finalised and reported
    /// through `onSegmentFinalized` like a rotation, so the caller can finish
    /// transcribing every slice before the underlying files are merged away.
    /// Leaves the recorder in `.processing`; drive it to `.completed`/`.failed`
    /// via `markProcessed`, and call `mergeCollectedSegments` once processing
    /// has drained.
    func stopAndCollectSegments() -> [String] {
        guard state == .recording || state == .paused || state == .interrupted else { return [] }
        stopRotationTimer()
        finalizeSegment()
        emitFinalizedSegment()
        stopMetering()
        level = 0
        AudioSessionManager.shared.deactivate()
        AudioSessionManager.shared.handler = nil
        setState(.processing)
        return segmentFileNames
    }

    /// Merges the collected segments into one canonical original recording (the
    /// preserved original) and returns its file name. Must be called only after
    /// every segment has finished processing, since merging removes the
    /// per-segment files. Returns `nil` when nothing was captured.
    func mergeCollectedSegments(_ names: [String]) async -> String? {
        guard !names.isEmpty else { return nil }
        if names.count == 1 { return names[0] }
        return await AudioFileMerger.merge(segmentFileNames: names)
    }

    /// Reports the pipeline outcome so the recorder can settle in a terminal
    /// state the UI can render.
    func markProcessed(success: Bool, failure: AudioCaptureFailure? = nil) {
        setState(success ? .completed : .failed, failure: failure)
    }

    /// Discards everything captured and returns to idle; used on Cancel.
    func discard() {
        stopRotationTimer()
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
        stopRotationTimer()
        segmentFileNames = []
        emittedSegmentNames = []
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

    // MARK: Rolling 30-second rotation

    /// Starts the repeating timer that rotates segments every
    /// `rollingSegmentDuration` seconds while recording.
    private func startRotationTimer() {
        stopRotationTimer()
        let timer = Timer(timeInterval: Self.rollingSegmentDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotateSegment() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func stopRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    /// Closes the current segment, hands it off for background processing, and
    /// immediately opens a fresh one so recording never pauses. The new segment
    /// belongs to the same capture (same person, same conversation); only the
    /// audio file boundary moves. If a new segment can't be opened the capture
    /// fails, but everything already finalised is safe and already reported.
    private func rotateSegment() {
        guard state == .recording else { return }
        finalizeSegment()
        emitFinalizedSegment()
        guard beginSegment() else {
            setState(.failed, failure: .recordingFailed)
            return
        }
    }

    /// Reports the most recently finalised segment through `onSegmentFinalized`,
    /// exactly once. A no-op when the last segment was dropped for being empty
    /// or was already reported.
    private func emitFinalizedSegment() {
        guard let last = segmentFileNames.last, !emittedSegmentNames.contains(last) else { return }
        emittedSegmentNames.insert(last)
        onSegmentFinalized?(last)
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
        stopRotationTimer()
        finalizeSegment()
        emitFinalizedSegment()
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
                startRotationTimer()
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
        stopRotationTimer()
        finalizeSegment()
        emitFinalizedSegment()
        stopMetering()
        setState(.interrupted)
    }

    func audioSessionDidEndInterruption(shouldResume: Bool) {
        guard state == .interrupted, resumeAfterInterruption, shouldResume else { return }
        try? AudioSessionManager.shared.reactivateAfterInterruption()
        if beginSegment() {
            setState(.recording)
            startMetering()
            startRotationTimer()
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
        stopRotationTimer()
        finalizeSegment()
        emitFinalizedSegment()
        stopMetering()
        setState(.interrupted)
    }
}
