import Foundation
import SwiftData

/// Turns an AIExtraction into real records: updates the person's profile,
/// creates gift ideas / reminders / important dates, and logs a timeline
/// interaction with an attached ConversationSummary.
enum ExtractionApplier {

    /// Which of an `AIExtraction`'s individual suggestions the user actually
    /// approved. Tracked per-item (not one flag per category) so rejecting a
    /// single bad gift idea doesn't also throw away the two good ones next
    /// to it. `summary`/`topics` aren't gated here — they always flow onto
    /// the interaction itself, same as before; this only covers suggestions
    /// that create separate, standalone records (gifts, reminders, dates)
    /// or otherwise mutate the person's profile (interests, personality
    /// notes).
    struct Options {
        var selectedInterests: Set<String> = []
        var selectedGiftIdeas: Set<String> = []
        var selectedReminders: Set<ExtractedReminder> = []
        var selectedImportantDates: Set<ExtractedDate> = []
        var selectedPersonalityNotes: Set<String> = []
        var createInteraction = true

        /// Every suggestion in `extraction` pre-approved — for call sites
        /// that skip a review step (nothing to review) or intentionally
        /// want everything applied without asking.
        static func allApproved(for extraction: AIExtraction, createInteraction: Bool = true) -> Options {
            Options(
                selectedInterests: Set(extraction.interests),
                selectedGiftIdeas: Set(extraction.giftIdeas),
                selectedReminders: Set(extraction.reminders),
                selectedImportantDates: Set(extraction.importantDates),
                selectedPersonalityNotes: Set(extraction.personalityNotes),
                createInteraction: createInteraction
            )
        }
    }

    @discardableResult
    static func apply(
        _ extraction: AIExtraction,
        to people: [Person],
        sourceText: String,
        interactionType: InteractionType,
        date: Date = .now,
        quality: Int = 3,
        voiceNote: VoiceNote? = nil,
        options: Options,
        context: ModelContext
    ) -> Interaction? {
        let approvedInterests = extraction.interests.filter(options.selectedInterests.contains)
        let approvedGiftIdeas = extraction.giftIdeas.filter(options.selectedGiftIdeas.contains)
        let approvedReminders = extraction.reminders.filter(options.selectedReminders.contains)
        let approvedImportantDates = extraction.importantDates.filter(options.selectedImportantDates.contains)
        let approvedPersonalityNotes = extraction.personalityNotes.filter(options.selectedPersonalityNotes.contains)

        for person in people {
            if !approvedInterests.isEmpty {
                person.addInterests(approvedInterests)
            }
            for idea in approvedGiftIdeas {
                let gift = GiftIdea(title: idea, person: person, notes: "From note on \(date.shortFormat)")
                context.insert(gift)
            }
            for extracted in approvedReminders {
                let reminder = Reminder(
                    title: extracted.title,
                    // Anchored to *now*, not the interaction's own date —
                    // for a past-dated interaction (a screenshot or voice
                    // note logged well after the fact), "follow up in 3
                    // days" has to mean 3 days from today, or a reminder
                    // for a months-old conversation would be born already
                    // overdue.
                    dueDate: extracted.dueDate ?? Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now,
                    type: .followUp,
                    person: person
                )
                context.insert(reminder)
                NotificationService.shared.schedule(reminder: reminder)
            }
            for extracted in approvedImportantDates {
                guard let dateValue = extracted.date else { continue }
                if extracted.title == "Birthday", person.birthday == nil {
                    person.birthday = dateValue
                } else {
                    let important = ImportantDate(title: extracted.title, date: dateValue, person: person)
                    context.insert(important)
                }
            }
            if !approvedPersonalityNotes.isEmpty {
                let addition = approvedPersonalityNotes.joined(separator: "\n")
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
            quality: quality,
            followUpNeeded: !approvedReminders.isEmpty,
            messageSummary: extraction.summary
        )
        interaction.people = people
        context.insert(interaction)
        // Only nudge closeness when this call is logging the interaction
        // itself — when it's just applying extras onto an interaction that
        // InteractionSaver already finalized, that call already applied the
        // quality adjustment once.
        InteractionSaver.applyClosenessImpact(of: interaction, to: people)

        // The AI Summary card shows everything the AI actually found,
        // approved or not — this is a record of what was extracted, not of
        // what was applied to the profile.
        let summary = ConversationSummary(extraction: extraction)
        summary.interaction = interaction
        summary.voiceNote = voiceNote
        context.insert(summary)

        return interaction
    }
}
