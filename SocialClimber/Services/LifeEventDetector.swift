import Foundation

/// Finds the handful of moments in a conversation that are worth remembering
/// as *events*, and throws out everything else.
///
/// The first version of this matched a marker phrase anywhere in a sentence
/// and then stored **the sentence itself** as the event. That produced
/// exactly the junk `MemoryFact.isLowQuality` was written to prevent one
/// layer down: `"yo rmb that like transfer u got into` recorded as something
/// that happened to the user (it is a question, about someone else),
/// `"Broke my scale"` filed under Health (a scale is not a body part), and
/// `"Bro got into ucb"` pinned on a contact named Oliver ("bro" is a
/// vocative, not a subject).
///
/// So a marker phrase is now only the *starting point*. Three things must
/// all hold before anything is recorded:
///
/// 1. **Subject.** The words immediately before the marker have to say who
///    this happened to: first person, or a named contact. "bro", "he", "my
///    brother", or nothing at all is ambiguous and is dropped. Second person
///    ("u got in") is dropped too: it means the *other* side of the
///    conversation, and in practice it is nearly always a question or a
///    reminiscence rather than news.
/// 2. **Object.** The words after the marker have to make the phrase mean
///    something. "broke my" needs a body part. "got into" needs somewhere to
///    have got into, and not "a fight".
/// 3. **Wording.** Questions, plans, hypotheticals, and chat-slang fragments
///    are not events.
///
/// The stored title is then *built* from the marker and its object ("Got
/// into ucb"), never quoted from the raw line.
enum LifeEventDetector {

    // MARK: Quality gate

    /// Wording that means the thing hasn't happened (or might never happen).
    /// A plan is a reminder, not an event.
    private static let hypotheticalMarkers = [
        "maybe", "might ", "if i ", "if he ", "if she ", "if they ", "if we ",
        "would ", "could ", "should ", "hope ", "hoping", "wish ", "want to ",
        "wanna", "gonna", "going to ", "plan to", "planning", "thinking about",
        "will ", "i'll ", "we'll ", "next time", "someday", "eventually",
        "what if", "supposed to", "trying to",
    ]

    /// Wording that makes a sentence a question or a callback to something
    /// already known, rather than a report of news.
    private static let questionMarkers = [
        "?", "rmb", "remember when", "remember that", "did you", "did u",
        "do you", "do u", "didn't you", "didnt u", "you still", "u still",
        "wait ", "how come", "what about",
    ]

    /// Words a real statement never ends on. A title finishing here means a
    /// sentence was cut mid-phrase.
    private static let danglingTailWords: Set<String> = [
        "a", "an", "the", "of", "and", "or", "only", "other", "to", "with",
        "for", "in", "at", "on", "my", "his", "her", "their", "that", "this",
        "is", "was", "were", "been", "just", "like", "so", "but", "because",
    ]

    /// Chat noise that gives away a fragment lifted straight out of a
    /// message. Mirrors `MemoryFact.chatFragmentTokens`, which exists for the
    /// same reason one layer down.
    private static let chatNoiseTokens: Set<String> = [
        "yo", "rmb", "ts", "ong", "fr", "frfr", "rn", "ngl", "istg", "tbh",
        "idk", "idc", "lol", "lmao", "lmfao", "smh", "bruh", "wtf", "tf",
        "af", "asf", "deadass", "lowkey", "highkey", "nah", "yea", "yeah",
    ]

    /// Whether a candidate event, heuristic or AI-produced, is solid enough
    /// to store. Applied to *every* candidate, so a chatty model can't route
    /// around the bar either.
    static func isWorthKeeping(_ event: ExtractedLifeEvent) -> Bool {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 6, title.count <= 140 else { return false }
        guard event.significance >= 2 else { return false }
        // A bare fragment rather than a statement of what happened. One word
        // is only ever enough when it carries the whole event on its own
        // ("Graduated"), which in practice means a long one.
        guard title.contains(" ") || title.count >= 9 else { return false }
        // A title that trails off in a function word is a truncated
        // sentence, not a statement ("Got into a school only 2 other").
        let lastWord = title.lowercased().split(separator: " ").last.map(String.init) ?? ""
        guard !danglingTailWords.contains(lastWord) else { return false }

        let lower = title.lowercased() + " " + event.detail.lowercased()
        if questionMarkers.contains(where: { lower.contains($0) }) { return false }
        if hypotheticalMarkers.contains(where: { lower.contains($0) }) { return false }
        // A stray quote mark means a chat line was captured verbatim.
        if title.contains("\"") || title.contains("“") { return false }
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !tokens.isDisjoint(with: chatNoiseTokens) { return false }
        return true
    }

    // MARK: Markers

    /// What has to follow a marker phrase for it to mean anything.
    private enum ObjectRule {
        /// The phrase is complete on its own ("graduated", "got engaged").
        case none
        /// Any reasonable noun phrase works ("moved to <somewhere>").
        case any
        /// Only these words do ("broke my <body part>").
        case oneOf(Set<String>)
    }

    private struct Marker {
        let phrase: String
        let kind: LifeEventKind
        let significance: Int
        let object: ObjectRule
    }

    private static let bodyParts: Set<String> = [
        "arm", "leg", "wrist", "ankle", "finger", "thumb", "nose", "rib",
        "ribs", "collarbone", "foot", "hand", "knee", "jaw", "toe", "elbow",
        "shoulder", "hip", "back", "tooth", "skull", "hip",
    ]

    /// Objects that turn an otherwise-promising phrase into a non-event.
    private static let bannedObjectTokens: Set<String> = [
        "fight", "argument", "trouble", "it", "that", "this", "there",
        "bed", "character", "beef",
    ]

    /// Words that end the object's noun phrase: whatever follows belongs to
    /// a different clause and must not be swept into the title.
    private static let phraseBoundaryWords: Set<String> = [
        "and", "but", "because", "so", "then", "when", "while", "that",
        "which", "who", "whom", "where", "only", "just", "like", "with",
        "without", "for", "from", "as", "than", "after", "before", "since",
        "at", "in", "on", "of", "to", "if", "though", "although", "also",
        "plus", "last", "next", "this", "yesterday", "today", "recently",
        "back", "over", "about",
    ]

    /// Nouns too generic to be an event on their own. "Got into a school"
    /// records nothing you didn't already know; "got into ucb" does.
    private static let genericObjectTokens: Set<String> = [
        "school", "college", "university", "uni", "program", "place", "job",
        "work", "class", "team", "one", "thing", "things", "stuff", "house",
        "home", "town", "city", "country", "state", "guy", "girl", "person",
        "people", "somewhere", "anywhere", "everywhere", "something",
        "anything", "everything", "course", "spot", "position",
    ]

    /// Deliberately short. Every phrase here has to be one that essentially
    /// only ever reports a completed change of state; anything looser
    /// ("started at", "won the") produced more noise than signal and is gone.
    private static let markers: [Marker] = [
        // Education
        .init(phrase: "got into", kind: .education, significance: 5, object: .any),
        .init(phrase: "got accepted to", kind: .education, significance: 5, object: .any),
        .init(phrase: "got accepted into", kind: .education, significance: 5, object: .any),
        .init(phrase: "committed to", kind: .education, significance: 5, object: .any),
        .init(phrase: "transferred to", kind: .education, significance: 4, object: .any),
        .init(phrase: "graduated", kind: .education, significance: 5, object: .none),
        .init(phrase: "got rejected from", kind: .education, significance: 4, object: .any),
        .init(phrase: "dropped out", kind: .education, significance: 5, object: .none),
        // Career
        .init(phrase: "got the job", kind: .career, significance: 5, object: .none),
        .init(phrase: "got the internship", kind: .career, significance: 5, object: .none),
        .init(phrase: "got an offer from", kind: .career, significance: 5, object: .any),
        .init(phrase: "got promoted", kind: .career, significance: 4, object: .none),
        .init(phrase: "got fired", kind: .career, significance: 5, object: .none),
        .init(phrase: "got laid off", kind: .career, significance: 5, object: .none),
        .init(phrase: "quit my job", kind: .career, significance: 5, object: .none),
        // Moving
        .init(phrase: "moved to", kind: .move, significance: 4, object: .any),
        .init(phrase: "moved back to", kind: .move, significance: 4, object: .any),
        .init(phrase: "moved in with", kind: .move, significance: 4, object: .any),
        // Health
        .init(phrase: "broke my", kind: .health, significance: 4, object: .oneOf(bodyParts)),
        .init(phrase: "had surgery", kind: .health, significance: 5, object: .none),
        .init(phrase: "got surgery", kind: .health, significance: 5, object: .none),
        .init(phrase: "was diagnosed with", kind: .health, significance: 5, object: .any),
        .init(phrase: "got diagnosed with", kind: .health, significance: 5, object: .any),
        .init(phrase: "in the hospital", kind: .health, significance: 5, object: .none),
        // Relationships
        .init(phrase: "broke up with", kind: .relationship, significance: 5, object: .any),
        .init(phrase: "got engaged", kind: .relationship, significance: 5, object: .none),
        .init(phrase: "got married", kind: .relationship, significance: 5, object: .none),
        .init(phrase: "got divorced", kind: .relationship, significance: 5, object: .none),
        .init(phrase: "started dating", kind: .relationship, significance: 4, object: .any),
        // Loss
        .init(phrase: "passed away", kind: .loss, significance: 5, object: .none),
        // Fallouts
        .init(phrase: "had a falling out", kind: .conflict, significance: 5, object: .none),
        .init(phrase: "stopped talking to", kind: .conflict, significance: 4, object: .any),
    ]

    // MARK: Subject

    private static let firstPersonTokens: Set<String> = ["i", "im", "i'm", "ive", "i've", "we", "weve", "we've"]
    private static let secondPersonTokens: Set<String> = ["u", "you", "ur", "your", "youre", "you're", "uve", "you've"]
    /// Words that make the subject somebody the app isn't tracking, or that
    /// are vocatives rather than subjects ("bro, got into ucb").
    private static let ambiguousSubjectTokens: Set<String> = [
        "bro", "bruh", "dude", "man", "he", "she", "they", "him", "her",
        "them", "someone", "somebody", "everyone", "mom", "dad", "mother",
        "father", "brother", "sister", "cousin", "friend", "girl", "guy",
    ]
    /// Filler that can sit between the subject and the marker without
    /// changing who the subject is ("i finally got into…").
    private static let subjectFillerTokens: Set<String> = [
        "just", "finally", "actually", "literally", "already", "also",
        "and", "so", "but", "then", "omg", "wait", "guess", "what",
    ]

    private enum Subject {
        /// "I", "we": whoever said the line.
        case speaker
        /// A contact named outright in the sentence.
        case named(String)
        /// Anything the sentence doesn't pin down, including second person.
        case unresolved
    }

    // MARK: Detection

    /// Reads past events out of one capture.
    ///
    /// In an imported chat digest the lines are `"Sender: text"`, so a line's
    /// sender is who "I" refers to: a sender that resolves to a known contact
    /// attributes to them, and, once at least one sender in the transcript
    /// has resolved, an unresolved sender is the user, since the user is
    /// never in their own contact list.
    static func detect(
        in text: String,
        knownPeople: [String],
        reference: Date
    ) -> [ExtractedLifeEvent] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { splitSpeaker($0, knownPeople: knownPeople) }
        let narratorIsIdentifiable = lines.contains { $0.speaker != nil }

        var found: [ExtractedLifeEvent] = []
        var seen = Set<String>()

        for parsed in lines {
            for rawSentence in parsed.body.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
                let sentence = rawSentence.trimmingCharacters(in: .whitespaces)
                guard sentence.count >= 6 else { continue }
                let lower = sentence.lowercased()

                // A question or a callback is never news, whatever else it
                // contains. Checked against the *source* line, not just the
                // title we'd build from it.
                if questionMarkers.contains(where: { lower.contains($0) }) { continue }
                if hypotheticalMarkers.contains(where: { lower.contains($0) }) { continue }

                guard let hit = firstMarker(in: sentence) else { continue }
                guard let object = object(after: hit.range, in: sentence, rule: hit.marker.object) else { continue }

                // Who it happened to. Anything ambiguous is dropped, never
                // guessed at: a wrong name on somebody's profile is worse
                // than a missing row.
                let subject = subject(before: hit.range, in: sentence, knownPeople: knownPeople)
                let subjects: [String]
                let aboutMe: Bool
                switch subject {
                case .named(let name):
                    subjects = [name]
                    aboutMe = false
                case .speaker:
                    if let speaker = parsed.speaker {
                        subjects = [speaker]
                        aboutMe = false
                    } else if parsed.hasSpeakerLabel && narratorIsIdentifiable {
                        subjects = []
                        aboutMe = true
                    } else if !parsed.hasSpeakerLabel {
                        subjects = []
                        aboutMe = true
                    } else {
                        continue
                    }
                case .unresolved:
                    continue
                }

                let title = buildTitle(marker: hit.marker, object: object)
                let candidate = ExtractedLifeEvent(
                    title: title,
                    date: CaptureParser.resolveRelativeDate(in: sentence, reference: reference),
                    kind: hit.marker.kind.rawValue,
                    significance: hit.marker.significance,
                    personNames: subjects,
                    aboutMe: aboutMe,
                    confidence: 0.6
                )
                guard isWorthKeeping(candidate) else { continue }
                let key = "\(hit.marker.kind.rawValue)|\(title.lowercased())|\(subjects.joined(separator: ","))|\(aboutMe)"
                guard seen.insert(key).inserted else { continue }
                found.append(candidate)
            }
        }
        // A conversation that suddenly "contains" a dozen life events is a
        // detector misfire, not a dramatic week. Keep the strongest few.
        return Array(found.sorted { $0.significance > $1.significance }.prefix(3))
    }

    /// Longest phrase first, so "moved back to" wins over "moved to" and
    /// "got accepted into" over nothing. Sorted once, not per sentence.
    private static let sortedMarkers = markers.sorted { $0.phrase.count > $1.phrase.count }

    /// Matched case-insensitively against the *original* sentence, so the
    /// returned range indexes into the text whose casing we want to keep.
    private static func firstMarker(in sentence: String) -> (marker: Marker, range: Range<String.Index>)? {
        for marker in sortedMarkers {
            if let range = sentence.range(of: marker.phrase, options: [.caseInsensitive]) {
                return (marker, range)
            }
        }
        return nil
    }

    /// The words following the marker, cut at the end of its noun phrase and
    /// validated against the marker's rule.
    ///
    /// Two separate failures live here. Taking a flat five words ran
    /// straight past the end of the phrase and stored the truncated middle
    /// of a sentence ("Got into a school only 2 other"), so the tail is now
    /// cut at the first word that starts a new clause. And a generic noun is
    /// not an event: "got into a school" says nothing that "got into ucb"
    /// says, so an object made only of generic words is rejected outright.
    /// Same principle as `MemoryFact.isLowQualityValue` refusing to store
    /// "education" as an interest.
    private static func object(
        after range: Range<String.Index>,
        in sentence: String,
        rule: ObjectRule
    ) -> String? {
        // Sliced from the original text, so the object keeps the casing the
        // user actually typed.
        let tail = String(sentence[range.upperBound...])
        var words = tail
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" })
            .map(String.init)
        // Everything from here on belongs to another clause, not to this
        // object. Without this, "got into a school only 2 other people got
        // into" kept running and stored the truncation.
        if let stop = words.firstIndex(where: { phraseBoundaryWords.contains($0.lowercased()) }) {
            words = Array(words[..<stop])
        }
        // Drop a leading article so "a school" is judged on "school".
        if let first = words.first?.lowercased(), ["a", "an", "the"].contains(first) {
            words.removeFirst()
        }
        words = Array(words.prefix(3))
        let object = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?'\""))
        let objectTokens = Set(object.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))

        guard objectTokens.isDisjoint(with: bannedObjectTokens) else { return nil }
        guard objectTokens.isDisjoint(with: chatNoiseTokens) else { return nil }

        switch rule {
        case .none:
            // The phrase already means something on its own, so an object is
            // optional; a generic one is simply dropped rather than failing
            // the whole match ("graduated finally" becomes "Graduated").
            return objectTokens.isDisjoint(with: genericObjectTokens) ? object : ""
        case .any:
            // This marker means nothing without a specific object.
            guard object.count >= 2 else { return nil }
            guard objectTokens.isDisjoint(with: genericObjectTokens) else { return nil }
            return object
        case .oneOf(let allowed):
            guard !objectTokens.isDisjoint(with: allowed) else { return nil }
            return object
        }
    }

    /// Reads the subject out of the words immediately before the marker.
    private static func subject(
        before range: Range<String.Index>,
        in sentence: String,
        knownPeople: [String]
    ) -> Subject {
        let head = String(sentence[sentence.startIndex..<range.lowerBound])
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        let tokens = head
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)

        // A named contact counts only when the name sits *immediately*
        // before the marker, which is what makes it the subject. Matching a
        // name anywhere earlier in the sentence would read "i told maya i
        // got into ucb" as Maya's news instead of the speaker's.
        for name in knownPeople {
            let full = name.lowercased()
            let first = (name.components(separatedBy: " ").first ?? name).lowercased()
            if head == full || head.hasSuffix(" " + full) { return .named(name) }
            if first.count >= 3, head == first || head.hasSuffix(" " + first) { return .named(name) }
        }

        // Otherwise the nearest pronoun-ish token decides, skipping filler.
        for token in tokens.reversed() {
            if subjectFillerTokens.contains(token) { continue }
            if firstPersonTokens.contains(token) { return .speaker }
            if secondPersonTokens.contains(token) { return .unresolved }
            if ambiguousSubjectTokens.contains(token) { return .unresolved }
            // Some other word is sitting where the subject should be; the
            // sentence isn't shaped the way this marker assumes.
            return .unresolved
        }
        // Nothing before the marker at all ("got into ucb"): the speaker.
        return .speaker
    }

    /// Builds the stored title from the marker and its object, rather than
    /// quoting the chat line. Only the first character is changed, so a
    /// proper noun keeps whatever casing it was typed with.
    private static func buildTitle(marker: Marker, object: String) -> String {
        let trimmed = object.trimmingCharacters(in: .whitespaces)
        let phrase = trimmed.isEmpty ? marker.phrase : "\(marker.phrase) \(trimmed)"
        return phrase.capitalizedFirst
    }

    /// Splits a `"Sender: text"` chat line into whether it carried a sender
    /// label at all, which known contact that sender is (`nil` for the
    /// narrator or a non-chat line), and the message body.
    private static func splitSpeaker(
        _ line: String,
        knownPeople: [String]
    ) -> (hasSpeakerLabel: Bool, speaker: String?, body: String) {
        guard let colon = line.firstIndex(of: ":") else { return (false, nil, line) }
        let head = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        // A sentence that merely contains a colon isn't a speaker label.
        guard !head.isEmpty, head.count <= 40, head.components(separatedBy: " ").count <= 4 else {
            return (false, nil, line)
        }
        let body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let match = knownPeople.first {
            $0.caseInsensitiveCompare(head) == .orderedSame
                || ($0.components(separatedBy: " ").first ?? $0).caseInsensitiveCompare(head) == .orderedSame
        }
        return (true, match, body)
    }
}
