import Foundation

/// Turns verbatim recogniser output into a lightly-cleaned reading copy —
/// without ever inventing words. The raw text is always preserved separately;
/// this only *removes* disfluency and *normalises* things it is highly
/// confident about.
///
/// Design rules, straight from the product requirements:
///   • Remove meaningless filler and immediate repeated fragments only.
///   • Repair obvious fragmentation using adjacent context, never hallucinate.
///   • Use known contacts as *hints* only — a spoken name is replaced with a
///     contact's canonical spelling only on a sufficiently strong match.
///
/// Pure and deterministic so every rule is unit-testable.
enum TranscriptCleaner {

    /// Standalone disfluencies safe to drop. Deliberately conservative — words
    /// that can be meaningful ("like", "so", "well", "right") are NOT included,
    /// because removing them can change meaning.
    private static let fillerTokens: Set<String> = [
        "um", "uh", "erm", "uhh", "umm", "hmm", "mmm", "eh", "ah", "er",
    ]

    /// Cleans `raw`. When `contactNames` is supplied, spoken names that match a
    /// contact strongly are normalised to the contact's spelling.
    static func clean(_ raw: String, contactNames: [String] = []) -> String {
        let collapsedWhitespace = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsedWhitespace.isEmpty else { return "" }

        // Work sentence by sentence so repair stays local and predictable.
        let words = tokenize(collapsedWhitespace)
        var kept: [String] = []
        var previousLower: String?

        for word in words {
            let bare = word.lowercasedWordCore
            // Drop pure filler tokens (only when the token is *only* filler,
            // e.g. "um" but never "umbrella").
            if fillerTokens.contains(bare) { continue }
            // Collapse an immediately repeated word ("the the" → "the",
            // "I I went" → "I went"). Case-insensitive, punctuation-insensitive.
            if let previousLower, previousLower == bare, !bare.isEmpty {
                continue
            }
            kept.append(word)
            previousLower = bare.isEmpty ? previousLower : bare
        }

        var cleaned = kept.joined(separator: " ")
        cleaned = normalizeNames(in: cleaned, contactNames: contactNames)
        cleaned = tidySpacing(cleaned)
        return cleaned
    }

    // MARK: - Name normalisation

    /// Replaces spoken tokens with a contact's canonical spelling only when the
    /// match is strong and unambiguous:
    ///   • exact case-insensitive match → normalise casing (always safe), or
    ///   • single-edit typo of a name ≥5 chars, and exactly one contact matches.
    /// Anything weaker is left exactly as spoken — a hint, never a rewrite.
    static func normalizeNames(in text: String, contactNames: [String]) -> String {
        guard !contactNames.isEmpty else { return text }
        // Build a lookup of individual name words (first names, etc.).
        let nameWords = contactNames
            .flatMap { $0.components(separatedBy: " ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        guard !nameWords.isEmpty else { return text }

        let canonicalByLower = Dictionary(nameWords.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        let tokens = tokenize(text)
        let mapped = tokens.map { token -> String in
            let (prefix, core, suffix) = splitAffixes(token)
            guard core.count >= 2 else { return token }
            let lower = core.lowercased()

            // Exact case-insensitive match: adopt canonical casing.
            if let canonical = canonicalByLower[lower], canonical != core {
                return prefix + canonical + suffix
            }
            // Strong near-match: single edit, name long enough, exactly one
            // contact within distance 1.
            if core.count >= 5 {
                let close = nameWords.filter { levenshtein(lower, $0.lowercased()) == 1 }
                if close.count == 1 {
                    return prefix + close[0] + suffix
                }
            }
            return token
        }
        return mapped.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Splits leading/trailing punctuation off a token so name matching sees
    /// just the word, e.g. "\"Sarah,\"" → ("\"", "Sarah", ",\"").
    private static func splitAffixes(_ token: String) -> (prefix: String, core: String, suffix: String) {
        let isCore: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" }
        let chars = Array(token)
        var start = 0
        var end = chars.count
        while start < end, !isCore(chars[start]) { start += 1 }
        while end > start, !isCore(chars[end - 1]) { end -= 1 }
        let prefix = String(chars[0..<start])
        let core = String(chars[start..<end])
        let suffix = String(chars[end..<chars.count])
        return (prefix, core, suffix)
    }

    private static func tidySpacing(_ text: String) -> String {
        var result = text
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        // No space before common punctuation.
        for p in [",", ".", "!", "?", ";", ":"] {
            result = result.replacingOccurrences(of: " \(p)", with: p)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Classic iterative Levenshtein edit distance. Small inputs (single
    /// words), so the simple O(mn) version is fine.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}

private extension String {
    /// Lowercased, with surrounding punctuation stripped — the comparison core
    /// of a token.
    var lowercasedWordCore: String {
        lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
    }
}
