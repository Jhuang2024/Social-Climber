import Foundation
import Speech
import AVFoundation

/// The one transcription service for the whole app. Every audio entry point
/// (Quick Capture, interaction logging, notes, debriefs, event capture, and
/// anything added later) routes through here so behaviour is identical
/// everywhere: on-device recognition, confidence-aware segments, timestamps,
/// per-chunk retry, and honest failure states.
///
/// Nothing here mutates SwiftData. It takes an audio file name and returns a
/// `TranscriptionResult` value; persistence and idempotency are the
/// `RecordingProcessor`'s job.
actor TranscriptionService {
    static let shared = TranscriptionService()

    /// How many times a single chunk is retried before it's abandoned (and the
    /// overall result marked partial) rather than failing the whole recording.
    static let maxChunkAttempts = 3

    enum TranscriptionError: Error {
        case unavailable
        case notAuthorized
        case noAudio
        case recognitionFailed
    }

    private init() {}

    // MARK: Authorization

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: Entry point

    /// Transcribes `fileName` (in `VoiceNote.directory`). Splits long audio into
    /// overlapping chunks, transcribes each with retry, and recombines them into
    /// one timestamped transcript. `contactNames` are used only as cleanup
    /// hints: never to invent or force-replace spoken names.
    func transcribe(fileName: String, contactNames: [String]) async -> TranscriptionResult {
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            AudioLog.warn("Speech not authorized (status \(status.rawValue))")
            return .empty
        }
        guard let recognizer = makeRecognizer(), recognizer.isAvailable else {
            AudioLog.warn("No available speech recognizer")
            return .empty
        }

        let url = VoiceNote.directory.appendingPathComponent(fileName)
        let totalDuration = await Self.duration(of: url)
        guard totalDuration > 0 else { return .empty }

        let windows = AudioChunker.chunks(totalDuration: totalDuration)
        var chunkResults: [(chunk: AudioChunker.Chunk, segments: [TranscriptSegment])] = []
        var anyChunkFailed = false

        for window in windows {
            // A single-chunk recording transcribes the file directly; longer
            // ones extract each window to a temp file.
            let chunkURL: URL
            let isTemp: Bool
            if windows.count == 1 {
                chunkURL = url
                isTemp = false
            } else if let extracted = await AudioFileMerger.extractSegment(from: url, start: window.start, end: window.end) {
                chunkURL = extracted
                isTemp = true
            } else {
                anyChunkFailed = true
                continue
            }
            defer { if isTemp { try? FileManager.default.removeItem(at: chunkURL) } }

            if let segments = await transcribeChunkWithRetry(url: chunkURL, recognizer: recognizer) {
                chunkResults.append((window, segments))
            } else {
                anyChunkFailed = true
                AudioLog.warn("Chunk \(window.index) failed after \(Self.maxChunkAttempts) attempts")
            }
        }

        let recombined = AudioChunker.recombine(chunkResults)
        let rawText = AudioChunker.joinedText(recombined)
        let cleaned = TranscriptCleaner.clean(rawText, contactNames: contactNames)
        let avgConfidence = recombined.isEmpty
            ? 0
            : recombined.map(\.confidence).reduce(0, +) / Double(recombined.count)

        AudioLog.info("Transcribed \(windows.count) chunk(s), \(recombined.count) segments, avgConf=\(String(format: "%.2f", avgConfidence)), partial=\(anyChunkFailed)")

        return TranscriptionResult(
            rawText: rawText,
            cleanedText: cleaned,
            segments: recombined,
            detectedLanguage: recognizer.locale.identifier,
            isPartial: anyChunkFailed && !recombined.isEmpty,
            averageConfidence: avgConfidence
        )
    }

    // MARK: Chunk transcription

    private func transcribeChunkWithRetry(url: URL, recognizer: SFSpeechRecognizer) async -> [TranscriptSegment]? {
        for attempt in 1...Self.maxChunkAttempts {
            do {
                return try await transcribeChunk(url: url, recognizer: recognizer)
            } catch {
                AudioLog.debug("Chunk attempt \(attempt) failed: \(error.localizedDescription)")
                // Brief backoff before retrying.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
            }
        }
        return nil
    }

    private func transcribeChunk(url: URL, recognizer: SFSpeechRecognizer) async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }

            var didResume = false
            let finish: (Result<[TranscriptSegment], Error>) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments.map { seg in
                    TranscriptSegment(
                        text: seg.substring,
                        start: seg.timestamp,
                        end: seg.timestamp + seg.duration,
                        confidence: Double(seg.confidence)
                    )
                }
                finish(.success(segments))
            }
        }
    }

    // MARK: Helpers

    /// Prefers a recognizer for the device's current language, falling back to
    /// the default. True auto-detect isn't offered by `SFSpeechRecognizer`, so
    /// we honour the user's locale, the closest the provider allows to
    /// multilingual handling.
    private func makeRecognizer() -> SFSpeechRecognizer? {
        if let preferred = Locale.preferredLanguages.first,
           let recognizer = SFSpeechRecognizer(locale: Locale(identifier: preferred)),
           recognizer.isAvailable {
            return recognizer
        }
        return SFSpeechRecognizer()
    }

    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite else { return 0 }
        return seconds
    }
}
