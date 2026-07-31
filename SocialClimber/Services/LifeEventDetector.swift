import Foundation

/// Finds the handful of moments in a conversation that are worth remembering
/// as *events*, and throws out everything else.
///
/// The whole risk with a "what's happened lately" feed is that it fills with
/// noise (every topic discussed, every plan floated, every joke) until it's
/// unreadable and untrusted. So this is written to say nothing most of the
/// time. Two gates do that work:
///
/// * `detect(in:…)` fires only on wording that describes a completed change
///   of state, and only in the past tense.
/// * `isWorthKeeping(_:)` is applied to *every* candidate, including ones a
///   real AI provider returned, so a chatty model can't route around the bar.
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

    /// Whether a candidate event, heuristic or AI-produced, is solid
    /// enough to store.
    static func isWorthKeeping(_ event: ExtractedLifeEvent) -> Bool {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 6, title.count <= 140 else { return false }
        guard event.significance >= 2 else { return false }

        let lower = title.lowercased() + " " + event.detail.lowercased()
        // A question is someone asking, not something that happened.
        if title.contains("?") { return false }
        if hypotheticalMarkers.contains(where: { lower.contains($0) }) { return false }
        // A bare fragment lifted out of a chat line rather than a statement
        // of what happened.
        if !title.contains(" ") { return false }
        return true
    }

    // MARK: Offline detection

    /// A phrase that marks a completed change of state, with the kind of
    /// event it implies and how much it usually matters.
    private struct Marker {
        let phrase: String
        let kind: LifeEventKind
        let significance: Int
    }

    private static let markers: [Marker] = [
        // Education
        .init(phrase: "got into", kind: .education, significance: 5),
        .init(phrase: "got accepted", kind: .education, significance: 5),
        .init(phrase: "accepted to", kind: .education, significance: 5),
        .init(phrase: "accepted into", kind: .education, significance: 5),
        .init(phrase: "committed to", kind: .education, significance: 5),
        .init(phrase: "graduated", kind: .education, significance: 5),
        .init(phrase: "got rejected from", kind: .education, significance: 4),
        .init(phrase: "transferred to", kind: .education, significance: 4),
        .init(phrase: "dropped out", kind: .education, significance: 5),
        // Career
        .init(phrase: "got the job", kind: .career, significance: 5),
        .init(phrase: "got the internship", kind: .career, significance: 5),
        .init(phrase: "got an offer", kind: .career, significance: 5),
        .init(phrase: "got promoted", kind: .career, significance: 4),
        .init(phrase: "got fired", kind: .career, significance: 5),
        .init(phrase: "got laid off", kind: .career, significance: 5),
        .init(phrase: "laid off", kind: .career, significance: 5),
        .init(phrase: "quit my job", kind: .career, significance: 5),
        .init(phrase: "quit his job", kind: .career, significance: 5),
        .init(phrase: "quit her job", kind: .career, significance: 5),
        .init(phrase: "started at", kind: .career, significance: 3),
        // Moving
        .init(phrase: "moved to", kind: .move, significance: 4),
        .init(phrase: "moved back", kind: .move, significance: 4),
        .init(phrase: "moved out", kind: .move, significance: 4),
        .init(phrase: "moved in with", kind: .move, significance: 4),
        // Health
        .init(phrase: "in the hospital", kind: .health, significance: 5),
        .init(phrase: "had surgery", kind: .health, significance: 5),
        .init(phrase: "got surgery", kind: .health, significance: 5),
        .init(phrase: "was diagnosed", kind: .health, significance: 5),
        .init(phrase: "got diagnosed", kind: .health, significance: 5),
        .init(phrase: "broke my", kind: .health, significance: 4),
        .init(phrase: "broke his", kind: .health, significance: 4),
        .init(phrase: "broke her", kind: .health, significance: 4),
        // Relationships
        .init(phrase: "broke up", kind: .relationship, significance: 5),
        .init(phrase: "got engaged", kind: .relationship, significance: 5),
        .init(phrase: "got married", kind: .relationship, significance: 5),
        .init(phrase: "started dating", kind: .relationship, significance: 4),
        .init(phrase: "got divorced", kind: .relationship, significance: 5),
        // Loss
        .init(phrase: "passed away", kind: .loss, significance: 5),
        .init(phrase: "the funeral", kind: .loss, significance: 5),
        // Achievement
        .init(phrase: "won the", kind: .achievement, significance: 4),
        .init(phrase: "won first", kind: .achievement, significance: 4),
        .init(phrase: "made the team", kind: .achievement, significance: 4),
        .init(phrase: "placed first", kind: .achievement, significance: 4),
        // Fallouts
        .init(phrase: "had a fight", kind: .conflict, significance: 4),
        .init(phrase: "falling out", kind: .conflict, significance: 5),
        .init(phrase: "stopped talking", kind: .conflict, significance: 4),
        .init(phrase: "blocked me", kind: .conflict, significance: 4),
        // Milestones
        .init(phrase: "got my license", kind: .milestone, significance: 3),
        .init(phrase: "got his license", kind: .milestone, significance: 3),
        .init(phrase: "got her license", kind: .milestone, significance: 3),
    ]

    /// Reads past events out of one capture.
    ///
    /// Attribution uses the strongest signal available. In an imported chat
    /// digest the lines are `"Sender: text"`, so whoever said a line is
    /// simply who it's about: a sender that resolves to a known contact
    /// attributes to them, and, once at least one sender in the same
    /// transcript has resolved, an unresolved sender is the narrator, since
    /// the user is never in their own contact list. For free-form notes it
    /// falls back to the names in the sentence, then to first-person
    /// wording. When none of that identifies anyone, the candidate is
    /// dropped rather than guessed at.
    static func detect(
        in text: String,
        knownPeople: [String],
        reference: Date
    ) -> [ExtractedLifeEvent] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { splitSpeaker($0, knownPeople: knownPeople) }

        // Once any sender in this transcript matches a contact, the other
        // senders can safely be read as the user themselves.
        let narratorIsIdentifiable = lines.contains { $0.speaker != nil }

        var found: [ExtractedLifeEvent] = []
        var seen = Set<String>()

        for parsed in lines {
            for sentence in parsed.body.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
                let statement = sentence.trimmingCharacters(in: .whitespaces)
                guard statement.count >= 6 else { continue }
                let lower = statement.lowercased()
                guard let marker = markers.first(where: { lower.contains($0.phrase) }) else { continue }

                let namedHere = CaptureParser.peopleNamed(in: statement, knownPeople: knownPeople)
                // "my brother got in", "her mom passed away": a real event,
                // but about somebody this app doesn't track, and pinning it
                // on the speaker would be plainly wrong. Checked before any
                // attribution so no branch can claim it.
                guard !namedHere.isEmpty || !aboutSomeoneElse(lower) else { continue }

                let subjects: [String]
                let aboutMe: Bool
                if !namedHere.isEmpty {
                    subjects = namedHere
                    aboutMe = false
                } else if let speaker = parsed.speaker {
                    // A contact talking about their own life.
                    subjects = [speaker]
                    aboutMe = false
                } else if parsed.hasSpeakerLabel && narratorIsIdentifiable {
                    subjects = []
                    aboutMe = true
                } else if !parsed.hasSpeakerLabel && mentionsSelf(lower) {
                    subjects = []
                    aboutMe = true
                } else {
                    // Nobody identifiable; better to drop it than to guess.
                    continue
                }

                let candidate = ExtractedLifeEvent(
                    title: statement.capitalizedFirst,
                    date: CaptureParser.resolveRelativeDate(in: statement, reference: reference),
                    kind: marker.kind.rawValue,
                    significance: marker.significance,
                    personNames: subjects,
                    aboutMe: aboutMe,
                    confidence: 0.6
                )
                guard isWorthKeeping(candidate) else { continue }
                let key = "\(marker.kind.rawValue)|\(lower)|\(subjects.joined(separator: ","))|\(aboutMe)"
                guard seen.insert(key).inserted else { continue }
                found.append(candidate)
            }
        }
        // A conversation that suddenly "contains" a dozen life events is a
        // detector misfire, not a dramatic week. Keep the strongest few.
        return Array(found.sorted { $0.significance > $1.significance }.prefix(4))
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

    /// Wording that puts the event on somebody the app doesn't track (a
    /// relative, a partner, a friend-of-a-friend) rather than on the
    /// speaker themselves.
    private static func aboutSomeoneElse(_ lower: String) -> Bool {
        let owners = ["mom", "mother", "dad", "father", "brother", "sister", "cousin",
                      "aunt", "uncle", "grandma", "grandpa", "friend", "roommate",
                      "coworker", "boss", "girlfriend", "boyfriend", "wife", "husband",
                      "son", "daughter", "kid", "parents", "family"]
        let possessives = ["my ", "his ", "her ", "their ", "our ", "your "]
        for possessive in possessives {
            for owner in owners where lower.contains(possessive + owner) {
                return true
            }
        }
        return false
    }

    private static func mentionsSelf(_ lower: String) -> Bool {
        let tokens = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains("i") || tokens.contains("im") || tokens.contains("my")
            || tokens.contains("we") || tokens.contains("our") || tokens.contains("me")
    }
}
