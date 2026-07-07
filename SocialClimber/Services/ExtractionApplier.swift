import Foundation
import SwiftData

/// Turns an AIExtraction into real records: updates the person's profile,
/// creates gift ideas / reminders / important dates, and logs a timeline
/// interaction with an attached ConversationSummary.
enum ExtractionApplier {

    struct Options {
        var addInterests = true
        var addGiftIdeas = true
        var addReminders = true
        var addImportantDates = true
        var addPersonalityNotes = true
        var createInteraction = true
    }

    @discardableResult
    static func apply(
        _ extraction: AIExtraction,
        to people: [Person],
        sourceText: String,
        interactionType: InteractionType,
        date: Date = .now,
        voiceNote: VoiceNote? = nil,
        options: Options = Options(),
        context: ModelContext
    ) -> Interaction? {
        for person in people {
            if options.addInterests {
                person.addInterests(extraction.interests)
            }
            if options.addGiftIdeas {
                for idea in extraction.giftIdeas {
                    let gift = GiftIdea(title: idea, person: person, notes: "From note on \(date.shortFormat)")
                    context.insert(gift)
                }
            }
            if options.addReminders {
                for extracted in extraction.reminders {
                    let reminder = Reminder(
                        title: extracted.title,
                        dueDate: extracted.dueDate ?? Calendar.current.date(byAdding: .day, value: 3, to: date) ?? date,
                        type: .followUp,
                        person: person
                    )
                    context.insert(reminder)
                    NotificationService.shared.schedule(reminder: reminder)
                }
            }
            if options.addImportantDates {
                for extracted in extraction.importantDates {
                    guard let dateValue = extracted.date else { continue }
                    if extracted.title == "Birthday", person.birthday == nil {
                        person.birthday = dateValue
                    } else {
                        let important = ImportantDate(title: extracted.title, date: dateValue, person: person)
                        context.insert(important)
                    }
                }
            }
            if options.addPersonalityNotes, !extraction.personalityNotes.isEmpty {
                let addition = extraction.personalityNotes.joined(separator: "\n")
                person.personalityNotes = person.personalityNotes.isEmpty
                    ? addition
                    : person.personalityNotes + "\n" + addition
            }
            person.markContacted(type: interactionType, date: date)
        }

        guard options.createInteraction else { return nil }

        let interaction = Interaction(
            type: interactionType,
            date: date,
            note: sourceText,
            topics: extraction.topics,
            followUpNeeded: !extraction.reminders.isEmpty,
            messageSummary: extraction.summary
        )
        interaction.people = people
        context.insert(interaction)

        let summary = ConversationSummary(extraction: extraction)
        summary.interaction = interaction
        summary.voiceNote = voiceNote
        context.insert(summary)

        return interaction
    }
}
