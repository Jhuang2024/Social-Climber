import Foundation
import AVFoundation

/// One place that defines "how Social Climber records speech", so every capture
/// screen produces identical, transcription-friendly audio.
///
/// Choices, all aimed at clear speech in a pocket without bloated files:
///   • AAC in an .m4a container — small, universally decodable.
///   • 32 kHz mono — captures speech (incl. fricative/consonant energy well
///     past 8 kHz) with headroom, while a single channel halves the size and
///     avoids phase issues from two pocket-muffled mics.
///   • ~48 kbps — transparent for voice, a fraction of "high-quality music".
enum SpeechAudioFormat {
    static let sampleRate: Double = 32_000
    static let channels: Int = 1
    static let bitRate: Int = 48_000

    /// Settings for `AVAudioRecorder`, tuned for speech rather than
    /// general-purpose audio.
    static var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// PCM format used by the offline enhancement engine. Float32, mono, at the
    /// recording sample rate.
    static var processingFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )
    }
}
