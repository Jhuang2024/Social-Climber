import Foundation
import SwiftData

@Model
final class VoiceNote {
    /// File name inside the app's Documents/VoiceNotes directory.
    var audioFileName: String?
    var transcript: String = ""
    var createdAt: Date = Date()

    var people: [Person] = []

    @Relationship(deleteRule: .cascade, inverse: \ConversationSummary.voiceNote)
    var aiSummary: ConversationSummary?

    init(audioFileName: String? = nil, transcript: String = "") {
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.createdAt = .now
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        return VoiceNote.directory.appendingPathComponent(audioFileName)
    }

    static var directory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
