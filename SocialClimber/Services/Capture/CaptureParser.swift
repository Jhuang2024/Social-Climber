import Foundation

/// Purely local, deterministic parsing of one natural-language capture:
/// interaction type, explicit sentiment, when it happened, and explicit
/// "remind me…" instructions with their relative dates resolved against the
/// capture's own timestamp. Zero network; shared by `CaptureProcessor` (the
/// parse-local-first step) and `MockAIService` (the offline fallback), so
/// both agree about what a phrase means.
enum CaptureParser {

    struct LocalParse {
        var interactionType: InteractionType?
        var interactionDate: Date?
        var explicitSentiment: Sentiment?
        var reminders: [(title: String, dueDate: Date?)] = []
    }

    static func parse(_ text: String, reference: Date) -> LocalParse {
        var result = LocalParse()
        result.interactionType = inferInteractionType(in: text)
        result.interactionDate = inferInteractionDate(in: text, reference: reference)
        result.explicitSentiment = explicitSentiment(in: text)
        result.reminders = explicitReminders(in: text, reference: reference)
        return result
    }

    // MARK: Interaction type

    private static let typeKeywords: [(InteractionType, [String])] = [
        // Order matters: more specific signals first, so "facetime call"
        // reads as a video call and "met at the party" as an event.
        (.videoCall, ["facetime", "video call", "video chat", "zoom", "google meet"]),
        (.event, ["at the party", "at a party", "at the event", "at an event", "meetup", "conference", "networking event", "at the wedding"]),
        (.call, ["called", "phone call", "on the phone", "gave me a call", "rang", "talked on the phone", "phoned"]),
        (.email, ["emailed", "sent an email", "got an email", "email from"]),
        (.message, ["texted", "text from", "messaged", "dm'd", "dmed", "sent me a message", "snapped", "replied to my"]),
        (.inPerson, ["coffee", "lunch", "dinner", "brunch", "boba", "drinks", "met up", "met with", "ran into", "hung out", "saw ", "grabbed", "walked with", "gym with", "at the gym", "came over", "went over", "stopped by", "had coffee", "caught up with", "meeting with", "met "]),
    ]

    /// The interaction kind the text itself states, or nil when it doesn't.
    static func inferInteractionType(in text: String) -> InteractionType? {
        let lower = " " + text.lowercased() + " "
        for (type, keywords) in typeKeywords {
            if keywords.contains(where: { lower.contains($0) }) { return type }
        }
        return nil
    }

    // MARK: Explicit sentiment

    private static let badWords = ["bad ", "awful", "terrible", "awkward", "hostile", "rough ", "went poorly", "went badly", "frustrating", "uncomfortable", "tense "]
    private static let greatWords = ["great ", "amazing", "awesome", "wonderful", "fantastic", "went really well", "so much fun", "incredible"]
    private static let goodWords = ["good ", "went well", "really nice", "fun ", "lovely "]

    /// A sentiment ONLY when the user explicitly described how it went;
    /// never inferred from topic or tone. Anything ambiguous returns nil so
    /// automated captures default to neutral and closeness is never moved
    /// on a guess.
    static func explicitSentiment(in text: String) -> Sentiment? {
        let lower = " " + text.lowercased() + " "
        if badWords.contains(where: { lower.contains($0) }) { return .bad }
        if greatWords.contains(where: { lower.contains($0) }) { return .great }
        if goodWords.contains(where: { lower.contains($0) }) { return .good }
        return nil
    }

    // MARK: When it happened

    /// The interaction's own date when the text states one ("yesterday",
    /// "last night", "on Tuesday", "this morning"), resolved *backward*
    /// against the capture date. Returns nil when the text says nothing —
    /// the capture timestamp is the right default then.
    static func inferInteractionDate(in text: String, reference: Date) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current

        if lower.contains("yesterday") || lower.contains("last night") {
            return calendar.date(byAdding: .day, value: -1, to: reference)
        }
        if lower.contains("this morning") || lower.contains("earlier today") || lower.contains("tonight") {
            return reference
        }
        if lower.contains("last week") {
            return calendar.date(byAdding: .day, value: -7, to: reference)
        }
        // "last tuesday" / "on tuesday" — the most recent such weekday
        // strictly before the capture.
        for (name, weekday) in weekdays {
            guard lower.contains("last \(name)") || lower.contains("on \(name)") else { continue }
            // "on Friday" can also be future ("remind me on Friday") — only
            // treat it as the interaction date with a past-tense cue nearby.
            if lower.contains("last \(name)") || lower.contains("met") || lower.contains("saw") || lower.contains("ran into") {
                return previous(weekday: weekday, before: reference, calendar: calendar)
            }
        }
        return nil
    }

    // MARK: Relative future dates

    private static let weekdays: [(String, Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7),
    ]

    /// Resolves the first future-pointing relative date phrase in `text`
    /// against `reference` ("Friday", "next Tuesday", "tomorrow", "next
    /// week", "in 3 days"). Returns nil when nothing resolvable is present —
    /// callers must treat that as "no date", never guess one.
    static func resolveRelativeDate(in text: String, reference: Date) -> Date? {
        let lower = text.lowercased()
        let calendar = Calendar.current

        if lower.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: reference)
        }
        if lower.contains("next week") {
            return calendar.date(byAdding: .day, value: 7, to: reference)
        }
        if lower.contains("next month") {
            return calendar.date(byAdding: .month, value: 1, to: reference)
        }
        if lower.contains("this weekend") {
            return next(weekday: 7, after: reference, calendar: calendar)
        }
        // "in N days" / "in N weeks"
        if let match = firstMatch(of: "in (\\d{1,2}) (day|days|week|weeks)", in: lower) {
            let amount = Int(match.1) ?? 0
            let unit = match.2.hasPrefix("week") ? 7 : 1
            return calendar.date(byAdding: .day, value: amount * unit, to: reference)
        }
        // "next friday" → the occurrence after the coming one when today is
        // close; keep it simple and honest: the first future occurrence.
        for (name, weekday) in weekdays {
            if lower.contains("next \(name)") || lower.contains(name) {
                return next(weekday: weekday, after: reference, calendar: calendar)
            }
        }
        // Explicit "<month> <day>" (future occurrence, current or next year).
        if let date = monthDayDate(in: lower, reference: reference, calendar: calendar) {
            return date
        }
        return nil
    }

    private static let monthNames: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
    ]

    private static func monthDayDate(in lower: String, reference: Date, calendar: Calendar) -> Date? {
        for (name, month) in monthNames {
            guard let range = lower.range(of: name) else { continue }
            let tail = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let dayString = tail.prefix { $0.isNumber }
            guard let day = Int(dayString), (1...31).contains(day) else { continue }
            var comps = DateComponents()
            comps.month = month
            comps.day = day
            comps.hour = 9
            // Never invent a year: pick the next occurrence of that
            // month/day at or after the reference date.
            return calendar.nextDate(after: reference, matching: comps, matchingPolicy: .nextTimePreservingSmallerComponents)
        }
        return nil
    }

    private static func next(weekday: Int, after reference: Date, calendar: Calendar) -> Date? {
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = 9
        return calendar.nextDate(after: reference, matching: comps, matchingPolicy: .nextTimePreservingSmallerComponents)
    }

    private static func previous(weekday: Int, before reference: Date, calendar: Calendar) -> Date? {
        var comps = DateComponents()
        comps.weekday = weekday
        return calendar.nextDate(after: reference, matching: comps, matchingPolicy: .nextTimePreservingSmallerComponents, direction: .backward)
    }

    private static func firstMatch(of pattern: String, in text: String) -> (String, String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 3,
              let whole = Range(match.range(at: 0), in: text),
              let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[whole]), String(text[first]), String(text[second]))
    }

    // MARK: Explicit reminders

    private static let explicitReminderMarkers = ["remind me", "follow up", "don't forget", "send this by", "circle back", "need to send", "need to reply"]

    /// Sentences that contain an explicit follow-up instruction, with any
    /// relative date resolved against the capture date. Sentences that only
    /// *imply* a follow-up are deliberately excluded — those become
    /// suggestions, not scheduled reminders.
    static func explicitReminders(in text: String, reference: Date) -> [(title: String, dueDate: Date?)] {
        sentences(in: text).compactMap { sentence in
            let lower = sentence.lowercased()
            guard explicitReminderMarkers.contains(where: { lower.contains($0) }) else { return nil }
            return (title: cleanReminderTitle(sentence), dueDate: resolveRelativeDate(in: sentence, reference: reference))
        }
    }

    private static func cleanReminderTitle(_ sentence: String) -> String {
        var title = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Remind me Friday to send him the intro" → "Send him the intro".
        if let range = title.lowercased().range(of: " to ") ,
           title.lowercased().hasPrefix("remind me") {
            title = String(title[range.upperBound...])
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        return title.isEmpty ? sentence : title.capitalizedFirst
    }

    private static func sentences(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 }
    }
}
