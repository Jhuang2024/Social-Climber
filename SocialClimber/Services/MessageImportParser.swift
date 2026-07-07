import Foundation

/// The result of locally parsing a pasted or OCR'd chat. The raw text is
/// always preserved verbatim; everything else is a best-effort convenience.
struct ParsedMessage {
    var rawText: String
    var cleanedText: String
    var speakers: [String]
    var summary: String
    var detectedDate: Date?
}

/// Purely local, on-device parsing of pasted/scanned message text. No AI, no
/// network — just heuristics for stripping obvious junk and building a preview.
enum MessageImportParser {
    private static let junkKeywords: Set<String> = [
        "delivered", "read", "sent", "seen", "today", "yesterday", "now",
        "imessage", "sms", "text message", "active now", "typing", "typing…",
        "online", "you sent", "this message was deleted", "message unavailable",
        "reply", "forwarded", "edited"
    ]

    static func parse(_ raw: String) -> ParsedMessage {
        let detectedDate = firstDate(in: raw)
        let rawLines = raw.components(separatedBy: .newlines)
        var speakers: [String] = []
        var contentLines: [String] = []

        for line in rawLines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let (name, rest) = speakerPrefix(trimmed) {
                if !speakers.contains(name) { speakers.append(name) }
                trimmed = rest
            }

            trimmed = stripTimestamps(trimmed).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isJunk(trimmed) else { continue }
            contentLines.append(trimmed)
        }

        let cleaned = contentLines.joined(separator: "\n")
        let summary = makeSummary(from: contentLines, fallback: raw)
        return ParsedMessage(
            rawText: raw,
            cleanedText: cleaned,
            speakers: speakers,
            summary: summary,
            detectedDate: detectedDate
        )
    }

    // MARK: Helpers

    /// Detects a leading "Name: message" speaker label and returns the name
    /// plus the remaining text. Rejects times, URLs, and anything that doesn't
    /// look like a short human name.
    private static func speakerPrefix(_ line: String) -> (name: String, rest: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let restStart = line.index(after: colon)
        let rest = String(line[restStart...]).trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, !rest.isEmpty else { return nil }
        // Must start with a letter (excludes "12:34" times).
        guard let first = name.first, first.isLetter else { return nil }
        // Reasonable name: 1–3 words, no digits, not a URL scheme.
        let words = name.split(separator: " ")
        guard words.count <= 3, name.count <= 32 else { return nil }
        guard !name.contains(where: \.isNumber) else { return nil }
        // "Me"/"Them" are OCRService's own bubble-color sender labels, not a
        // real contact's name — leave them attached to the line (readable,
        // useful context for the AI summary) but never suggest them as a
        // new contact to create.
        guard !["http", "https", "www", "note", "info", "me", "them"].contains(name.lowercased()) else { return nil }
        guard !rest.hasPrefix("//") else { return nil }
        return (name, rest)
    }

    private static func stripTimestamps(_ input: String) -> String {
        var s = input
        let patterns = [
            "\\[[^\\]]*\\]",                                   // [10:04]
            "\\b\\d{1,2}:\\d{2}(?::\\d{2})?\\s?(?:[AaPp][Mm])?\\b", // 3:45 PM
            "\\b\\d{1,2}[/.\\-]\\d{1,2}(?:[/.\\-]\\d{2,4})?\\b"     // 10/12/23
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
            }
        }
        // Collapse whitespace left behind.
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func isJunk(_ line: String) -> Bool {
        let normalized = line.lowercased().trimmingCharacters(in: .whitespaces)
        if junkKeywords.contains(normalized) { return true }
        // Lines that are only punctuation / emoji reactions with no words.
        let hasLetters = normalized.contains { $0.isLetter }
        if !hasLetters && normalized.count <= 3 { return true }
        return false
    }

    private static func makeSummary(from lines: [String], fallback: String) -> String {
        let meaningful = lines.filter { $0.contains(where: \.isLetter) }
        let source = meaningful.isEmpty
            ? fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            : meaningful.prefix(3).joined(separator: " ")
        let collapsed = source.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return truncate(collapsed, to: 220)
    }

    private static func truncate(_ text: String, to max: Int) -> String {
        guard text.count > max else { return text }
        let end = text.index(text.startIndex, offsetBy: max)
        return text[text.startIndex..<end].trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Words/patterns that mean a detector match actually names a day, as
    /// opposed to just a bare clock time.
    private static let dayWords: Set<String> = [
        "today", "yesterday", "tomorrow",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Finds the first *reliable* date in the text — one that names an
    /// actual day, not just a clock time.
    ///
    /// `NSDataDetector` happily matches a bare time like "3:45 PM" (nearly
    /// every message timestamp in a chat screenshot) and returns a `Date`
    /// for it by silently defaulting the day component to *today*. Trusting
    /// that blindly is exactly the "assume it happened today" mistake this
    /// exists to avoid — a screenshot from three weeks ago would get logged
    /// as today just because it shows a time of day. Only a match whose
    /// matched text actually names a day (a numeric date, a month, a
    /// weekday, or a relative day word) is trusted.
    private static func firstDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let date = match.date, let matchRange = Range(match.range, in: text) else { continue }
            let matchedText = text[matchRange].lowercased()
            let hasNumericDate = matchedText.range(of: "\\d{1,2}[/.\\-]\\d{1,2}", options: .regularExpression) != nil
            let hasDayWord = dayWords.contains { matchedText.contains($0) }
            guard hasNumericDate || hasDayWord else { continue }
            return date
        }
        return nil
    }
}
