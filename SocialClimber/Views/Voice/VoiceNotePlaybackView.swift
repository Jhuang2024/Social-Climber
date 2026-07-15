import SwiftUI
import SwiftData
import AVFoundation

/// Shows a saved voice note's original audio, its transcript (cleaned by
/// default, with a verbatim toggle), its processing state, and controls to
/// retry enhancement/transcription. Reusable anywhere a `VoiceNote` needs to be
/// reviewed.
struct VoiceNotePlaybackView: View {
    @Bindable var voiceNote: VoiceNote
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]

    @State private var player = AudioPlaybackController()
    @State private var showVerbatim = false
    @State private var isRetrying = false

    var body: some View {
        FormSectionCard("Voice Note", icon: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                statusRow

                if voiceNote.audioURL != nil {
                    playbackControls
                }

                if let failure = voiceNote.failureReason, voiceNote.processingState == .failed {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !displayedTranscript.isEmpty {
                    Text(displayedTranscript)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if !voiceNote.rawTranscript.isEmpty && voiceNote.rawTranscript != voiceNote.cleanedTranscript {
                        Toggle(verbatimToggleLabel, isOn: $showVerbatim)
                            .font(.caption)
                            .tint(.green)
                    }
                }

                if !voiceNote.conversation.isEmpty {
                    DisclosureGroup("Who said what") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(voiceNote.conversation) { line in
                                ConversationLineRow(line: line)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption.weight(.semibold))
                    .tint(SCTheme.accent)
                }

                retryControls
            }
        }
        .onDisappear { player.stop() }
    }

    private var displayedTranscript: String {
        showVerbatim ? voiceNote.rawTranscript : (voiceNote.transcript.isEmpty ? voiceNote.cleanedTranscript : voiceNote.transcript)
    }

    /// For a translated note the "verbatim" copy is the original-language
    /// recording, so name it that way.
    private var verbatimToggleLabel: String {
        voiceNote.wasTranslated ? "Show original (\(RecordingLanguage.from(languageCode: voiceNote.detectedLanguage).longLabel))" : "Show verbatim"
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
            Text(voiceNote.processingState.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateColor)
            if voiceNote.averageConfidence > 0 {
                Spacer()
                Text("Confidence \(Int(voiceNote.averageConfidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var playbackControls: some View {
        Button {
            player.toggle(url: voiceNote.audioURL)
        } label: {
            Label(player.isPlaying ? "Pause original" : "Play original",
                  systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(SCTheme.accent)
    }

    @ViewBuilder
    private var retryControls: some View {
        if voiceNote.audioURL != nil {
            HStack {
                Button {
                    retry()
                } label: {
                    if isRetrying {
                        ProgressView()
                    } else {
                        Label("Retry transcription", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(SCTheme.accent)
                .disabled(isRetrying || voiceNote.processingState == .processing)
                Spacer()
            }
        }
    }

    private func retry() {
        isRetrying = true
        Task {
            await RecordingProcessor.shared.process(
                note: voiceNote,
                contactNames: people.map(\.name),
                context: context,
                force: true
            )
            // Keep the editable transcript in step when it was empty/failed.
            if voiceNote.transcript.isEmpty { voiceNote.transcript = voiceNote.cleanedTranscript }
            isRetrying = false
        }
    }

    private var stateIcon: String {
        switch voiceNote.processingState {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .processing: return "waveform"
        default: return "waveform.circle"
        }
    }

    private var stateColor: Color {
        switch voiceNote.processingState {
        case .completed: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

/// Minimal AVAudioPlayer wrapper for reviewing the original recording.
@Observable
final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(url: URL?) {
        if isPlaying { stop(); return }
        guard let url else { return }
        do {
            try AudioSessionManager.shared.activateForPlayback()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            isPlaying = true
        } catch {
            AudioLog.error("Playback failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        AudioSessionManager.shared.deactivate()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
