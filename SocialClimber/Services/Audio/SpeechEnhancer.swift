import Foundation
import AVFoundation
import Accelerate

/// A conservative, offline speech-enhancement pass applied to a *copy* of a
/// recording before transcription. The goal is intelligibility for pocket
/// audio, not a studio-clean sound, so every stage is deliberately gentle and
/// the original file is never touched.
///
/// The chain, ordered for audio quality (the product spec lists the same
/// stages):
///   1. Analyse speech level and noise floor.
///   2. High-pass to remove sub-bass rumble from walking / pocket handling.
///   3. Gentle downward expansion keyed to the measured noise floor, to pull
///      down constant background (traffic, AC, hum, fabric) between words
///      without gating speech.
///   4. Speech-presence EQ (light low cut + a small 2–4 kHz lift).
///   5. Light, soft-knee compression so quiet speech rises without clipping.
///   6. Guarded make-up gain to a target level: skipped when the signal is
///      essentially silence/noise so we never amplify a hiss into "speech".
///
/// Aggressive denoising is intentionally avoided: it eats consonants and
/// changes words, which is worse than a little background noise.
enum SpeechEnhancer {

    /// What the analysis pass measured. All levels in dBFS.
    struct Analysis: Equatable {
        var peakDBFS: Double
        var speechLevelDBFS: Double   // ~90th percentile frame level
        var noiseFloorDBFS: Double    // ~10th percentile frame level
        var snrDB: Double
        var durationSeconds: Double

        /// Almost nothing above the noise floor, treat as no usable speech.
        var isEffectivelySilent: Bool { speechLevelDBFS < -45 && snrDB < 3 }
        /// There is signal, but it's very quiet relative to full scale.
        var isTooQuiet: Bool { speechLevelDBFS < -38 }
        /// Speech is present but buried in noise.
        var isNoisy: Bool { snrDB < 6 && speechLevelDBFS >= -38 }
    }

    struct Result {
        /// File name (in `VoiceNote.directory`) of the enhanced copy, or `nil`
        /// if enhancement was skipped and the original should be used directly.
        let enhancedFileName: String?
        let analysis: Analysis
    }

    /// Target speech level for make-up gain. Comfortably below full scale to
    /// leave headroom for the compressor's peaks.
    private static let targetSpeechDBFS: Double = -18
    /// Never apply more than this much make-up gain: prevents turning a quiet,
    /// noisy pocket recording into a wall of amplified hiss.
    private static let maxMakeupGainDB: Double = 18

    // MARK: Entry point

    /// Produces an enhanced copy of `originalFileName`. Runs off the main
    /// thread. Never overwrites the original; on any failure it returns a
    /// result whose `enhancedFileName` is `nil` so the caller falls back to the
    /// untouched original.
    static func enhance(originalFileName: String) async -> Result {
        await Task.detached(priority: .utility) {
            do {
                return try process(originalFileName: originalFileName)
            } catch {
                AudioLog.error("Enhancement failed, using original: \(error.localizedDescription)")
                return Result(enhancedFileName: nil, analysis: Analysis(
                    peakDBFS: 0, speechLevelDBFS: -20, noiseFloorDBFS: -60, snrDB: 40,
                    durationSeconds: 0
                ))
            }
        }.value
    }

    // MARK: Pipeline

    private static func process(originalFileName: String) throws -> Result {
        let url = VoiceNote.directory.appendingPathComponent(originalFileName)
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        var samples = try readMonoSamples(from: file)
        let duration = Double(samples.count) / sampleRate

        // 1. Analyse the raw signal.
        let rawAnalysis = analyze(samples: samples, sampleRate: sampleRate, duration: duration)
        AudioLog.debug("Enhance analysis: speech=\(Int(rawAnalysis.speechLevelDBFS))dBFS noise=\(Int(rawAnalysis.noiseFloorDBFS))dBFS snr=\(Int(rawAnalysis.snrDB))dB dur=\(Int(duration))s")

        // If there's essentially nothing there, don't fabricate signal, return
        // the analysis so the caller can raise the right failure state.
        guard !rawAnalysis.isEffectivelySilent else {
            return Result(enhancedFileName: nil, analysis: rawAnalysis)
        }

        // 2. High-pass ~85 Hz to kill walking/handling rumble.
        applyBiquad(&samples, coeff: Biquad.highPass(fc: 85, sampleRate: sampleRate))

        // 3. Gentle downward expansion below (noiseFloor + margin).
        let gateThreshold = dbToLinear(rawAnalysis.noiseFloorDBFS + 6)
        applyDownwardExpander(&samples, threshold: Float(gateThreshold), ratio: 1.5, sampleRate: sampleRate)

        // 4. Speech-presence EQ: a shallow low-shelf cut and a modest presence
        //    peak. Small gains only: enough to lift intelligibility.
        applyBiquad(&samples, coeff: Biquad.lowShelf(fc: 200, sampleRate: sampleRate, gainDB: -2))
        applyBiquad(&samples, coeff: Biquad.peaking(fc: 3000, sampleRate: sampleRate, q: 1.0, gainDB: 3))

        // 5. Light compression (2:1, soft knee).
        applyCompressor(&samples, thresholdDB: -20, ratio: 2, sampleRate: sampleRate)

        // 6. Guarded make-up gain toward the target speech level.
        let post = analyze(samples: samples, sampleRate: sampleRate, duration: duration)
        if !post.isEffectivelySilent {
            var gainDB = targetSpeechDBFS - post.speechLevelDBFS
            gainDB = min(maxMakeupGainDB, max(0, gainDB)) // only ever raise, and cap it
            // Don't amplify a noisy signal hard; scale the gain back the
            // noisier it is, so we never blast up pure background.
            if post.snrDB < 10 { gainDB *= max(0.3, post.snrDB / 10) }
            applyGain(&samples, db: gainDB)
        }

        // Final safety limiter so nothing clips after all the above.
        peakLimit(&samples, ceiling: 0.985)

        let outName = "enhanced-\(originalFileName)"
        try writeMonoSamples(samples, to: VoiceNote.directory.appendingPathComponent(outName), sampleRate: sampleRate)
        return Result(enhancedFileName: outName, analysis: rawAnalysis)
    }

    // MARK: Analysis

    static func analyze(samples: [Float], sampleRate: Double, duration: Double) -> Analysis {
        guard !samples.isEmpty else {
            return Analysis(peakDBFS: -120, speechLevelDBFS: -120, noiseFloorDBFS: -120, snrDB: 0, durationSeconds: duration)
        }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        // Frame the signal (~20 ms) and take per-frame RMS in dBFS.
        let frameLength = max(1, Int(sampleRate * 0.02))
        var frameLevels: [Double] = []
        frameLevels.reserveCapacity(samples.count / frameLength + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameLength, samples.count)
            var meanSq: Float = 0
            samples[i..<end].withUnsafeBufferPointer { ptr in
                vDSP_measqv(ptr.baseAddress!, 1, &meanSq, vDSP_Length(end - i))
            }
            let rms = sqrt(Double(meanSq))
            frameLevels.append(linearToDb(rms))
            i = end
        }
        let sorted = frameLevels.sorted()
        let noiseFloor = percentile(sorted, 0.10)
        let speechLevel = percentile(sorted, 0.90)
        return Analysis(
            peakDBFS: linearToDb(Double(peak)),
            speechLevelDBFS: speechLevel,
            noiseFloorDBFS: noiseFloor,
            snrDB: max(0, speechLevel - noiseFloor),
            durationSeconds: duration
        )
    }

    /// Analyses a file without enhancing it; used by the processor to decide
    /// failure states even when enhancement is skipped.
    static func analyzeFile(_ fileName: String) -> Analysis? {
        let url = VoiceNote.directory.appendingPathComponent(fileName)
        guard let file = try? AVAudioFile(forReading: url),
              let samples = try? readMonoSamples(from: file) else { return nil }
        let sr = file.processingFormat.sampleRate
        return analyze(samples: samples, sampleRate: sr, duration: Double(samples.count) / sr)
    }

    // MARK: - DSP building blocks

    /// Biquad coefficients (normalised so a0 == 1).
    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

        static func highPass(fc: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
            let w0 = 2 * Double.pi * fc / sampleRate
            let cw = cos(w0), sw = sin(w0)
            let alpha = sw / (2 * q)
            let a0 = 1 + alpha
            return Biquad(
                b0: Float((1 + cw) / 2 / a0),
                b1: Float(-(1 + cw) / a0),
                b2: Float((1 + cw) / 2 / a0),
                a1: Float(-2 * cw / a0),
                a2: Float((1 - alpha) / a0)
            )
        }

        static func peaking(fc: Double, sampleRate: Double, q: Double, gainDB: Double) -> Biquad {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * fc / sampleRate
            let cw = cos(w0), sw = sin(w0)
            let alpha = sw / (2 * q)
            let a0 = 1 + alpha / A
            return Biquad(
                b0: Float((1 + alpha * A) / a0),
                b1: Float(-2 * cw / a0),
                b2: Float((1 - alpha * A) / a0),
                a1: Float(-2 * cw / a0),
                a2: Float((1 - alpha / A) / a0)
            )
        }

        static func lowShelf(fc: Double, sampleRate: Double, gainDB: Double) -> Biquad {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * fc / sampleRate
            let cw = cos(w0), sw = sin(w0)
            let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / 0.707 - 1) + 2)
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            let a0 = (A + 1) + (A - 1) * cw + twoSqrtAAlpha
            return Biquad(
                b0: Float(A * ((A + 1) - (A - 1) * cw + twoSqrtAAlpha) / a0),
                b1: Float(2 * A * ((A - 1) - (A + 1) * cw) / a0),
                b2: Float(A * ((A + 1) - (A - 1) * cw - twoSqrtAAlpha) / a0),
                a1: Float(-2 * ((A - 1) + (A + 1) * cw) / a0),
                a2: Float(((A + 1) + (A - 1) * cw - twoSqrtAAlpha) / a0)
            )
        }
    }

    /// Direct Form I biquad, applied in place.
    static func applyBiquad(_ samples: inout [Float], coeff c: Biquad) {
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<samples.count {
            let x0 = samples[i]
            let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            samples[i] = y0
        }
    }

    /// Gentle downward expander: attenuates signal that sits below `threshold`,
    /// pulling background down between words. Low ratio so speech onsets aren't
    /// chopped. Envelope-follows to avoid pumping.
    static func applyDownwardExpander(_ samples: inout [Float], threshold: Float, ratio: Float, sampleRate: Double) {
        guard threshold > 0 else { return }
        let attack = expCoeff(ms: 5, sampleRate: sampleRate)
        let release = expCoeff(ms: 80, sampleRate: sampleRate)
        var env: Float = 0
        for i in 0..<samples.count {
            let mag = abs(samples[i])
            let coeff = mag > env ? attack : release
            env = coeff * env + (1 - coeff) * mag
            if env < threshold, env > 0 {
                // gain = (env/threshold)^(ratio-1), always ≤ 1.
                let gain = pow(env / threshold, ratio - 1)
                samples[i] *= max(0.05, gain) // floor so we attenuate, never mute
            }
        }
    }

    /// Soft-knee compressor with make-up baked out (make-up handled separately).
    static func applyCompressor(_ samples: inout [Float], thresholdDB: Double, ratio: Double, sampleRate: Double) {
        let threshold = Float(dbToLinear(thresholdDB))
        let attack = expCoeff(ms: 10, sampleRate: sampleRate)
        let release = expCoeff(ms: 120, sampleRate: sampleRate)
        var env: Float = 0
        let slope = Float(1 - 1 / ratio)
        for i in 0..<samples.count {
            let mag = abs(samples[i])
            let coeff = mag > env ? attack : release
            env = coeff * env + (1 - coeff) * mag
            if env > threshold {
                let overDB = 20 * log10(max(env, 1e-6) / threshold)
                let reductionDB = -overDB * slope
                let gain = Float(pow(10, Double(reductionDB) / 20))
                samples[i] *= gain
            }
        }
    }

    static func applyGain(_ samples: inout [Float], db: Double) {
        guard db > 0.01 else { return }
        var g = Float(dbToLinear(db))
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsmul(base, 1, &g, base, 1, vDSP_Length(buf.count))
        }
    }

    /// Hard-ish peak limiter to keep everything under `ceiling` after gain.
    static func peakLimit(_ samples: inout [Float], ceiling: Float) {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > ceiling, peak > 0 else { return }
        var scale = ceiling / peak
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(buf.count))
        }
    }

    // MARK: - I/O

    static func readMonoSamples(from file: AVAudioFile) throws -> [Float] {
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }
        // Downmix to mono by averaging channels.
        var mono = [Float](repeating: 0, count: count)
        for ch in 0..<channels {
            let ptr = channelData[ch]
            for i in 0..<count { mono[i] += ptr[i] }
        }
        var divisor = Float(channels)
        mono.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsdiv(base, 1, &divisor, base, 1, vDSP_Length(buf.count))
        }
        return mono
    }

    static func writeMonoSamples(_ samples: [Float], to url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: SpeechAudioFormat.bitRate,
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "SpeechEnhancer", code: 1)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try outFile.write(from: buffer)
    }

    // MARK: - Math helpers

    private static func linearToDb(_ x: Double) -> Double { x <= 1e-9 ? -120 : 20 * log10(x) }
    private static func dbToLinear(_ db: Double) -> Double { pow(10, db / 20) }

    static func percentile(_ sortedAscending: [Double], _ p: Double) -> Double {
        guard !sortedAscending.isEmpty else { return -120 }
        let idx = Int((Double(sortedAscending.count - 1) * p).rounded())
        return sortedAscending[max(0, min(sortedAscending.count - 1, idx))]
    }

    /// One-pole smoothing coefficient for a given time constant.
    private static func expCoeff(ms: Double, sampleRate: Double) -> Float {
        Float(exp(-1.0 / (sampleRate * ms / 1000.0)))
    }
}
