import XCTest
import Foundation
@testable import SocialClimber

/// Tests the pure analysis pieces of the enhancement pipeline (no audio files).
final class SpeechEnhancerTests: XCTestCase {

    func testPercentile() {
        let sorted = [-60.0, -50, -40, -30, -20, -10]
        XCTAssertEqual(SpeechEnhancer.percentile(sorted, 0.0), -60)
        XCTAssertEqual(SpeechEnhancer.percentile(sorted, 1.0), -10)
        // ~median.
        let mid = SpeechEnhancer.percentile(sorted, 0.5)
        XCTAssertTrue(mid <= -30 && mid >= -40)
    }

    func testPercentileEmpty() {
        XCTAssertEqual(SpeechEnhancer.percentile([], 0.5), -120)
    }

    func testSilenceIsEffectivelySilent() {
        let samples = [Float](repeating: 0, count: 16_000)
        let analysis = SpeechEnhancer.analyze(samples: samples, sampleRate: 16_000, duration: 1)
        XCTAssertTrue(analysis.isEffectivelySilent)
    }

    func testLoudToneIsNotSilent() {
        let sampleRate = 16_000.0
        let samples = sine(freq: 300, amplitude: 0.5, sampleRate: sampleRate, seconds: 1)
        let analysis = SpeechEnhancer.analyze(samples: samples, sampleRate: sampleRate, duration: 1)
        XCTAssertFalse(analysis.isEffectivelySilent)
        XCTAssertFalse(analysis.isTooQuiet)
        XCTAssertGreaterThan(analysis.peakDBFS, -12)
    }

    func testVeryQuietToneFlaggedTooQuiet() {
        let sampleRate = 16_000.0
        let samples = sine(freq: 300, amplitude: 0.005, sampleRate: sampleRate, seconds: 1)
        let analysis = SpeechEnhancer.analyze(samples: samples, sampleRate: sampleRate, duration: 1)
        XCTAssertTrue(analysis.isTooQuiet)
    }

    func testHighPassAttenuatesLowFrequency() {
        let sampleRate = 32_000.0
        var low = sine(freq: 30, amplitude: 0.8, sampleRate: sampleRate, seconds: 0.5) // sub-rumble
        let before = rms(low)
        SpeechEnhancer.applyBiquad(&low, coeff: SpeechEnhancer.Biquad.highPass(fc: 85, sampleRate: sampleRate))
        let after = rms(low)
        // 30 Hz is well below the 85 Hz corner → strongly attenuated.
        XCTAssertLessThan(after, before * 0.6)
    }

    func testGainOnlyRaises() {
        var s: [Float] = [0.1, -0.1, 0.2]
        SpeechEnhancer.applyGain(&s, db: 6) // ~2x
        XCTAssertEqual(s[0], 0.2, accuracy: 0.02)
    }

    func testTranscriptionResultHasSpeech() {
        XCTAssertFalse(TranscriptionResult.empty.hasSpeech)
        var r = TranscriptionResult.empty
        r.rawText = "hello"
        XCTAssertTrue(r.hasSpeech)
    }

    // MARK: helpers

    private func sine(freq: Double, amplitude: Float, sampleRate: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { i in
            amplitude * Float(sin(2 * Double.pi * freq * Double(i) / sampleRate))
        }
    }

    private func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        let sumSq = s.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSq / Float(s.count)).squareRoot()
    }
}
