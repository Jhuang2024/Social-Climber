import Foundation
import SwiftData

@Model
final class ConversationSummary {
    var summary: String = ""
    var peopleMentioned: [String] = []
    var topics: [String] = []
    var interests: [String] = []
    var giftIdeas: [String] = []
    var importantDates: [String] = []
    var reminders: [String] = []
    var followUpQuestions: [String] = []
    var personalityNotes: [String] = []
    var confidence: Double = 0
    var createdAt: Date = Date()

    var interaction: Interaction?
    var voiceNote: VoiceNote?

    init(extraction: AIExtraction) {
        self.summary = extraction.summary
        self.peopleMentioned = extraction.peopleMentioned
        self.topics = extraction.topics
        self.interests = extraction.interests
        self.giftIdeas = extraction.giftIdeas
        self.importantDates = extraction.importantDates.map(\.display)
        self.reminders = extraction.reminders.map(\.title)
        self.followUpQuestions = extraction.followUpQuestions
        self.personalityNotes = extraction.personalityNotes
        self.confidence = extraction.confidence
        self.createdAt = .now
    }
}
