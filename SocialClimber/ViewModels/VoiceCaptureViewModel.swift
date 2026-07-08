import Foundation
import AVFoundation
import Speech
import Observation

/// Drives the voice note flow: record audio → transcribe (on-device Speech,
/// with a mock fallback) → run AI extraction. No AI logic lives in views.
@Observable
final class VoiceCaptureViewModel {

    var isRecording = false
    var isTranscribing = false
    var isAnalyzing = false
    var transcript = ""
    var extraction: AIExtraction?
    /// Set when the configured AI provider failed and `extraction` is the
    /// deterministic local fallback instead, shown as an informational
    /// notice, never blocks review/apply.
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private(set) var audioFileName: String?

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is off. You can type the note instead, or enable the mic in Settings."
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let fileName = "\(UUID().uuidString).m4a"
            let url = VoiceNote.directory.appendingPathComponent(fileName)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            audioFileName = fileName
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcribeRecording()
    }

    // MARK: Transcription

    private func transcribeRecording() {
        guard let audioFileName else { return }
        let url = VoiceNote.directory.appendingPathComponent(audioFileName)
        isTranscribing = true

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                    self.applyMockTranscript()
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = true
                recognizer.recognitionTask(with: request) { result, error in
                    DispatchQueue.main.async {
                        if let result, result.isFinal {
                            let text = result.bestTranscription.formattedString
                            if !text.isEmpty {
                                self.transcript += (self.transcript.isEmpty ? "" : "\n") + text
                            }
                            self.isTranscribing = false
                        } else if error != nil {
                            self.applyMockTranscript()
                        }
                    }
                }
            }
        }
    }

    /// Fallback when speech recognition is unavailable (e.g. Simulator):
    /// insert an editable placeholder so the flow can still be completed.
    private func applyMockTranscript() {
        if transcript.isEmpty {
            transcript = "(Transcription unavailable; edit this note.) Caught up today. "
        }
        isTranscribing = false
    }

    // MARK: AI extraction

    func analyze(knownPeople: [String]) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        // Never blocks: falls back to a deterministic local extraction if the
        // configured AI provider fails, so review/apply always has something
        // to work with.
        let outcome = await AIExtractionCoordinator.extract(from: text, knownPeople: knownPeople)
        extraction = outcome.extraction
        errorMessage = outcome.notice
    }

    func discardRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let audioFileName {
            try? FileManager.default.removeItem(at: VoiceNote.directory.appendingPathComponent(audioFileName))
        }
        audioFileName = nil
    }
}
