import Foundation
import AVFoundation

/// Owns the app's shared `AVAudioSession` configuration for voice capture and
/// reports interruptions and route changes to whoever is recording.
///
/// Centralised so every capture screen gets identical, correct behaviour:
///   • speech-tuned session category/mode,
///   • the clearest available input route for the current device state,
///   • a stable route that doesn't switch mid-recording,
///   • clean interruption/route-change signals for recovery.
final class AudioSessionManager: NSObject {
    static let shared = AudioSessionManager()

    /// Delegate that receives interruption/route events. The active recorder
    /// installs itself here for the duration of a capture.
    weak var handler: AudioSessionEventHandler?

    private let session = AVAudioSession.sharedInstance()
    private var observing = false

    private override init() { super.init() }

    // MARK: Configuration

    /// Configures and activates the session for voice recording. Uses
    /// `.playAndRecord` (so playback of the original recording works without
    /// reconfiguring) with a speech-appropriate mode, and allows Bluetooth and
    /// wired mics so AirPods / headsets work. Starts observing interruptions
    /// and route changes.
    func activateForRecording() throws {
        // `.spokenAudio`-style handling: `.default` mode keeps the system's
        // mild voice processing, which helps intelligibility for pocket audio
        // without the aggressive AGC of `.measurement`. Bluetooth options let
        // AirPods and headsets act as the input.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers]
        )
        try preferClearestInput()
        try session.setActive(true, options: [])
        startObserving()
    }

    /// Reactivates the session after an interruption without reselecting the
    /// route: recovery must not move the mic out from under an in-progress
    /// recording.
    func reactivateAfterInterruption() throws {
        try session.setActive(true, options: [])
    }

    /// Configures the session for playback of a saved recording.
    func activateForPlayback() throws {
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: [])
    }

    func deactivate() {
        stopObserving()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Route selection

    /// Picks the input most likely to capture the clearest speech for the
    /// current device state and pins it as preferred so the OS won't silently
    /// switch away during the recording.
    ///
    /// Preference order: a wired headset/mic, then Bluetooth HFP (AirPods /
    /// headsets), then the built-in mic. When the phone is in a pocket, an
    /// in-ear or wired mic is dramatically clearer than the muffled built-in,
    /// so we favour it when present. For the built-in mic we prefer the
    /// bottom/front data source to avoid the rear mic aimed at fabric.
    func preferClearestInput() throws {
        guard let inputs = session.availableInputs, !inputs.isEmpty else { return }
        let ranked = inputs.sorted { rank(of: $0.portType) > rank(of: $1.portType) }
        guard let best = ranked.first else { return }

        // For the built-in mic, steer toward the data source pointed at the
        // speaker, not the environment, when the device exposes a choice.
        if best.portType == .builtInMic, let sources = best.dataSources, !sources.isEmpty {
            let preferred = sources.first { $0.orientation == .bottom }
                ?? sources.first { $0.orientation == .front }
                ?? sources.first
            if let preferred {
                try? best.setPreferredDataSource(preferred)
            }
        }
        try session.setPreferredInput(best)
    }

    /// Higher rank = preferred. Kept as a small pure function so the ordering
    /// is easy to reason about and adjust.
    private func rank(of port: AVAudioSession.Port) -> Int {
        switch port {
        case .headsetMic, .usbAudio, .lineIn: return 40          // wired mic
        case .bluetoothHFP: return 30                             // AirPods / BT headset mic
        case .builtInMic: return 20
        case .carAudio: return 10
        default: return 0
        }
    }

    /// A short, non-identifying description of the current input route for
    /// logging (never contains user content).
    var currentInputDescription: String {
        session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
    }

    // MARK: Observation

    private func startObserving() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: session)
        nc.addObserver(self, selector: #selector(handleMediaReset(_:)),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    private func stopObserving() {
        guard observing else { return }
        observing = false
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            DispatchQueue.main.async { self.handler?.audioSessionDidBeginInterruption() }
        case .ended:
            let shouldResume: Bool
            if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            } else {
                shouldResume = false
            }
            DispatchQueue.main.async { self.handler?.audioSessionDidEndInterruption(shouldResume: shouldResume) }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }
        DispatchQueue.main.async { self.handler?.audioSessionRouteDidChange(reason: reason) }
    }

    @objc private func handleMediaReset(_ note: Notification) {
        DispatchQueue.main.async { self.handler?.audioSessionMediaServicesWereReset() }
    }
}

/// Events the active recorder reacts to for interruption recovery and route
/// stability. All delivered on the main queue.
protocol AudioSessionEventHandler: AnyObject {
    func audioSessionDidBeginInterruption()
    func audioSessionDidEndInterruption(shouldResume: Bool)
    func audioSessionRouteDidChange(reason: AVAudioSession.RouteChangeReason)
    func audioSessionMediaServicesWereReset()
}
