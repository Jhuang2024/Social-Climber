import Foundation

/// Purely local, deterministic parsing of one natural-language capture:
/// interaction type, explicit sentiment, when it happened, and explicit
/// "remind me…" instructions with their relative dates resolved against the
/// capture's own timestamp. Zero network; shared by `CaptureProcessor` (the
/// parse-local-first step) and `MockAIService` (the offline fallback), so
/// both agree about what a phrase means.
enum CaptureParser {

    struct LocalParse: Sendable {
        var interactionType: InteractionType?
        var interactionDate: Date?
        var explicitSentiment: Sentiment?
        var reminders: [(title: String, dueDate: Date?, personNames: [String])] = []
    }

    static func parse(_ text: String, reference: Date, knownPeople: [String] = []) -> LocalParse {
        var result = LocalParse()
        result.interactionType = inferInteractionType(in: text)
        result.interactionDate = inferInteractionDate(in: text, reference: reference)
        result.explicitSentiment = explicitSentiment(in: text)
        result.reminders = explicitReminders(in: text, reference: reference, knownPeople: knownPeople)
        return result
    }

    // MARK: Person-mention matching (shared attribution helper)

    /// Which of `knownPeople` are actually named in `text`, by full name
    /// or first name, at a word boundary so "Sam" never matches inside
    /// "Samantha". This is the single mechanism the capture pipeline uses
    /// to attribute an extracted fact, reminder, or date to a specific
    /// person instead of defaulting to whichever person was resolved
    /// first for the whole capture.
    static func peopleNamed(in text: String, knownPeople: [String]) -> [String] {
        let lower = " " + text.lowercased() + " "
        return knownPeople.filter { name in
            guard !name.isEmpty else { return false }
            let first = name.components(separatedBy: " ").first ?? name
            return containsWord(name.lowercased(), in: lower) || containsWord(first.lowercased(), in: lower)
        }
    }

    /// Word-boundary containment so a short name never matches as a
    /// substring of an unrelated longer word.
    static func containsWord(_ word: String, in paddedLowerText: String) -> Bool {
        guard !word.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
            return paddedLowerText.contains(" \(word) ")
        }
        let range = NSRange(paddedLowerText.startIndex..., in: paddedLowerText)
        return regex.firstMatch(in: paddedLowerText, range: range) != nil
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

    /// Sentiment cue phrases, as sequences of whole words. They are matched on
    /// word boundaries, never as substrings (see `containsSignal`) — matching
    /// substrings is what used to make "talked it through" trip "rough",
    /// "intense but fun" trip "tense", and "badly" trip "bad", flipping plainly
    /// fine interactions to negative and dragging the relationship score down.
    private static let badPhrases: [[String]] = [
        ["bad"], ["awful"], ["terrible"], ["awkward"], ["hostile"], ["rough"],
        ["went", "poorly"], ["went", "badly"], ["frustrating"], ["uncomfortable"], ["tense"],
    ]
    private static let greatPhrases: [[String]] = [
        ["great"], ["amazing"], ["awesome"], ["wonderful"], ["fantastic"],
        ["went", "really", "well"], ["so", "much", "fun"], ["incredible"],
    ]
    private static let goodPhrases: [[String]] = [
        ["good"], ["went", "well"], ["really", "nice"], ["fun"], ["lovely"],
    ]

    /// Words that flip the cue right after them, so "not bad", "wasn't
    /// awkward", "never tense" aren't read as negative (and, applied the same
    /// way, "not great" isn't read as positive). Apostrophes are stripped
    /// before matching, so the contracted forms are spelled without them.
    private static let negators: Set<String> = [
        "not", "no", "never", "hardly", "barely", "without", "nothing",
        "wasnt", "isnt", "arent", "werent", "didnt", "dont", "doesnt",
        "cant", "couldnt", "wouldnt", "hadnt", "aint",
    ]

    /// A sentiment ONLY when the user explicitly described how it went; never
    /// inferred from topic or tone. Whole words are matched, negations are
    /// respected, and a note carrying BOTH a positive and a negative cue is
    /// treated as ambiguous (returns nil) rather than forcing the negative — so
    /// automated captures default to neutral and closeness is never moved on a
    /// guess.
    static func explicitSentiment(in text: String) -> Sentiment? {
        let words = tokenize(text)
        let negative = containsSignal(badPhrases, in: words)
        let great = containsSignal(greatPhrases, in: words)
        let good = containsSignal(goodPhrases, in: words)
        let positive = great || good
        // Mixed signals ("amazing, if a bit awkward at first") are genuinely
        // ambiguous: don't guess, and never let one incidental negative word
        // override an otherwise positive note.
        if negative && positive { return nil }
        if negative { return .bad }
        if great { return .great }
        if good { return .good }
        return nil
    }

    /// Lowercases, drops apostrophes (so contractions stay one word), and
    /// splits on any non-alphanumeric run into whole words.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// True when any cue phrase appears as a run of whole words that isn't
    /// immediately negated (a negator within the two words before it).
    private static func containsSignal(_ phrases: [[String]], in words: [String]) -> Bool {
        for phrase in phrases where !phrase.isEmpty && phrase.count <= words.count {
            for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase {
                let preceding = words[max(0, start - 2)..<start]
                if !preceding.contains(where: { negators.contains($0) }) { return true }
            }
        }
        return false
    }

    // MARK: When it happened

    /// The interaction's own date when the text states one ("yesterday",
    /// "last night", "on Tuesday", "this morning"), resolved *backward*
    /// against the capture date. Returns nil when the text says nothing;
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
        // "last tuesday" / "on tuesday": the most recent such weekday
        // strictly before the capture.
        for (name, weekday) in weekdays {
            guard lower.contains("last \(name)") || lower.contains("on \(name)") else { continue }
            // "on Friday" can also be future ("remind me on Friday"); only
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
    /// week", "in 3 days"). Returns nil when nothing resolvable is present;
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
    /// relative date resolved against the capture date and attributed to
    /// whichever known people are actually named in that sentence (empty
    /// when it names no one in particular). Sentences that only *imply* a
    /// follow-up are deliberately excluded; those become suggestions, not
    /// scheduled reminders.
    static func explicitReminders(in text: String, reference: Date, knownPeople: [String] = []) -> [(title: String, dueDate: Date?, personNames: [String])] {
        sentences(in: text).compactMap { sentence in
            let lower = sentence.lowercased()
            guard explicitReminderMarkers.contains(where: { lower.contains($0) }) else { return nil }
            return (
                title: cleanReminderTitle(sentence),
                dueDate: resolveRelativeDate(in: sentence, reference: reference),
                personNames: peopleNamed(in: sentence, knownPeople: knownPeople)
            )
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
