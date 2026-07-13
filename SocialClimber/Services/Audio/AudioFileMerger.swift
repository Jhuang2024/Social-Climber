import Foundation
import AVFoundation

/// Concatenates the crash-safe segments a capture was split into back into one
/// canonical original recording, and extracts time windows for chunked
/// transcription.
///
/// Implemented with PCM read/write (via `SpeechEnhancer`'s helpers) rather than
/// `AVAssetExportSession`, so there's no version-specific async export API to
/// guard and no deprecation warnings. Segments are always recorded with the
/// same speech settings, so their sample rates match.
enum AudioFileMerger {

    /// Merges `segmentFileNames` (inside `VoiceNote.directory`, in order) into a
    /// single new .m4a and returns its file name. On any failure it falls back
    /// to the first segment so the recording is never lost. Returns `nil` only
    /// when there is nothing to merge.
    static func merge(segmentFileNames: [String]) async -> String? {
        guard let first = segmentFileNames.first else { return nil }
        guard segmentFileNames.count > 1 else { return first }

        return await Task.detached(priority: .utility) {
            let dir = VoiceNote.directory
            var combined: [Float] = []
            var sampleRate = SpeechAudioFormat.sampleRate
            for name in segmentFileNames {
                let url = dir.appendingPathComponent(name)
                guard let file = try? AVAudioFile(forReading: url),
                      let samples = try? SpeechEnhancer.readMonoSamples(from: file) else {
                    AudioLog.warn("Skipping unreadable segment during merge")
                    continue
                }
                sampleRate = file.processingFormat.sampleRate
                combined.append(contentsOf: samples)
            }
            guard !combined.isEmpty else { return first }

            let outName = "\(UUID().uuidString).m4a"
            let outURL = dir.appendingPathComponent(outName)
            do {
                try SpeechEnhancer.writeMonoSamples(combined, to: outURL, sampleRate: sampleRate)
            } catch {
                AudioLog.error("Segment merge write failed: \(error.localizedDescription)")
                return first
            }
            // Merge succeeded; remove the now-redundant segments.
            for name in segmentFileNames {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            AudioLog.info("Merged \(segmentFileNames.count) segments into one recording")
            return outName
        }.value
    }

    /// Extracts the `[start, end)` window of `fileURL` (seconds) into a
    /// temporary .m4a for chunked transcription. Returns `nil` on failure so the
    /// caller can mark that chunk failed without losing the rest.
    static func extractSegment(from fileURL: URL, start: TimeInterval, end: TimeInterval) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: fileURL),
                  let samples = try? SpeechEnhancer.readMonoSamples(from: file) else {
                return nil
            }
            let sampleRate = file.processingFormat.sampleRate
            let startIndex = max(0, Int(start * sampleRate))
            let endIndex = min(samples.count, Int(end * sampleRate))
            guard startIndex < endIndex else { return nil }
            let slice = Array(samples[startIndex..<endIndex])

            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("chunk-\(UUID().uuidString).m4a")
            do {
                try SpeechEnhancer.writeMonoSamples(slice, to: outURL, sampleRate: sampleRate)
            } catch {
                AudioLog.warn("Chunk extraction failed: \(error.localizedDescription)")
                return nil
            }
            return outURL
        }.value
    }
}
