import Foundation
import SwiftData

/// Reads the conversations you had *before* these features existed.
///
/// Past Events and relationship inference both run inside `CaptureProcessor`,
/// which means they only ever see captures processed after the feature
/// shipped. Everything already on the timeline (months of imported Instagram
/// threads, voice notes, typed captures) was processed by an earlier build
/// that had nowhere to put a life event and no notion of reading a
/// relationship off a conversation. Without this pass, Past Events starts
/// empty on a database full of history, and every contact keeps whatever
/// placeholder category it was created with.
///
/// So this walks the stored text of past interactions and voice notes once
/// and applies exactly the same two extractions the live pipeline applies.
/// Deliberately offline-only: it uses the `LifeEventDetector` /
/// `RelationshipInference` heuristics rather than re-running AI extraction,
/// because a retroactive sweep must not silently spend the user's API budget
/// or block launch on hundreds of network round-trips.
///
/// Safe to run repeatedly. Life events de-duplicate on
/// `LifeEvent.dedupeKey`, and relationship writes go through
/// `RelationshipInference.apply`, which never overrides a human's choice.
enum HistoryBackfill {

    private static let versionKey = "historyBackfillVersion"
    /// Bump to re-run the sweep after the detectors get meaningfully better.
    /// v2: the first detector matched a marker anywhere in a sentence and
    /// stored the raw line as the event, which produced chat fragments
    /// attributed to the wrong person entirely.
    /// v3: the object was taken as a flat five words, so it ran past the end
    /// of its own phrase and stored the truncation ("Got into a school only
    /// 2 other"), and a generic noun was accepted as an event at all.
    /// Everything either of them wrote has to go, not just be added to.
    private static let currentVersion = 3

    /// Interactions with less text than this carry nothing worth scanning
    /// ("Marked as contacted", a bare "Logged contact with…").
    private static let minimumTextLength = 12

    struct Summary {
        var eventsCreated = 0
        var relationshipsInferred = 0
        var scanned = 0

        var isEmpty: Bool { eventsCreated == 0 && relationshipsInferred == 0 }
    }

    /// Runs once per `currentVersion`. Called on app activation.
    ///
    /// A version bump means the detector itself changed, so anything the
    /// previous one wrote and nobody has touched since is discarded before
    /// re-deriving. Conversations are the source of truth here; a stored
    /// event produced by a detector we no longer trust is not worth keeping
    /// just because it exists. Events a person confirmed, edited, or
    /// dismissed are left alone.
    @MainActor
    @discardableResult
    static func runIfNeeded(context: ModelContext) -> Summary {
        let defaults = UserDefaults.standard
        let previous = defaults.integer(forKey: versionKey)
        guard previous < currentVersion else { return Summary() }
        if previous > 0 { discardMachineWrittenEvents(context: context) }
        let summary = run(context: context)
        defaults.set(currentVersion, forKey: versionKey)
        return summary
    }

    /// Deletes every life event automatic extraction produced and no human
    /// has since confirmed, edited, or dismissed.
    @MainActor
    static func discardMachineWrittenEvents(context: ModelContext) {
        let events = (try? context.fetch(FetchDescriptor<LifeEvent>())) ?? []
        for event in events where !event.isUserTouched {
            context.delete(event)
        }
        try? context.save()
    }

    /// The sweep itself, exposed separately so Settings can offer an explicit
    /// "rescan" and so tests can call it directly.
    @MainActor
    @discardableResult
    static func run(context: ModelContext) -> Summary {
        var summary = Summary()
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard !people.isEmpty else { return summary }
        let knownNames = people.map(\.name).filter { !$0.isEmpty }

        var seenEventKeys = Set(((try? context.fetch(FetchDescriptor<LifeEvent>())) ?? []).map(\.dedupeKey))
        // Best relationship read per person across their whole history, so
        // one weak signal in an old thread can't beat a clear statement in a
        // newer one; applied after the scan, strongest first.
        var bestRelationship: [PersistentIdentifier: ExtractedRelationship] = [:]

        func scan(text: String, date: Date, attendees: [Person], captureUUID: UUID?, interactionUUID: UUID?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minimumTextLength, !attendees.isEmpty else { return }
            summary.scanned += 1

            for candidate in LifeEventDetector.detect(in: trimmed, knownPeople: knownNames, reference: date) {
                guard LifeEventDetector.isWorthKeeping(candidate) else { continue }
                let attributed = matched(candidate.personNames, among: attendees)
                let aboutMe = candidate.aboutMe && attributed.isEmpty
                guard aboutMe || attributed.count == 1 else { continue }
                let person = aboutMe ? nil : attributed.first
                let kind = LifeEventKind(rawValue: candidate.kind) ?? .other
                let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = LifeEvent.dedupeKey(title: title, kind: kind, personUUID: person?.uuid, aboutMe: aboutMe)
                guard seenEventKeys.insert(key).inserted else { continue }

                let event = LifeEvent(
                    title: title,
                    detail: candidate.detail,
                    // No resolvable date in the text means the conversation's
                    // own date is the best anchor available, and it's an
                    // approximation: the event was *discussed* then, not
                    // necessarily on that day.
                    date: candidate.date ?? date,
                    isDateApproximate: candidate.date == nil,
                    kind: kind,
                    significance: candidate.significance,
                    aboutMe: aboutMe,
                    person: person,
                    confidence: candidate.confidence,
                    sourceCaptureUUID: captureUUID,
                    sourceInteractionUUID: interactionUUID
                )
                context.insert(event)
                summary.eventsCreated += 1
            }

            for attendee in attendees where !attendee.categoryIsUserSet || !attendee.relationshipIsUserSet {
                let guesses = RelationshipInference.guesses(in: trimmed, subjectNames: [attendee.name])
                guard let guess = guesses.first else { continue }
                let id = attendee.persistentModelID
                if (bestRelationship[id]?.confidence ?? 0) < guess.confidence {
                    bestRelationship[id] = guess
                }
            }
        }

        // Interactions carry the richest text: an imported Instagram digest
        // keeps its full "Sender: message" transcript in `rawImportText`,
        // which is exactly the shape the speaker attribution wants.
        let interactions = (try? context.fetch(FetchDescriptor<Interaction>())) ?? []
        for interaction in interactions.sorted(by: { $0.date > $1.date }) {
            let text = interaction.rawImportText.isEmpty ? interaction.note : interaction.rawImportText
            scan(
                text: text,
                date: interaction.date,
                attendees: interaction.people,
                captureUUID: interaction.sourceCaptureUUID,
                interactionUUID: interaction.uuid
            )
        }

        // Voice notes whose transcript never became an interaction's note.
        let voiceNotes = (try? context.fetch(FetchDescriptor<VoiceNote>())) ?? []
        for note in voiceNotes.sorted(by: { $0.createdAt > $1.createdAt }) {
            let text = note.cleanedTranscript.isEmpty ? note.transcript : note.cleanedTranscript
            scan(
                text: text,
                date: note.createdAt,
                attendees: note.people,
                captureUUID: nil,
                interactionUUID: nil
            )
        }

        for person in people {
            guard let guess = bestRelationship[person.persistentModelID] else { continue }
            if case .applied = RelationshipInference.apply(guess, to: person) {
                summary.relationshipsInferred += 1
            }
        }

        if !summary.isEmpty { try? context.save() }
        return summary
    }

    /// Same rule the live pipeline uses: match reported names against the
    /// people actually on this record, never the whole database, and never
    /// fall back to "whoever was first".
    private static func matched(_ names: [String], among people: [Person]) -> [Person] {
        guard !names.isEmpty else { return [] }
        var result: [Person] = []
        for name in names {
            guard let person = people.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    || (!$0.nickname.isEmpty && $0.nickname.caseInsensitiveCompare(name) == .orderedSame)
                    || $0.firstName.caseInsensitiveCompare(name) == .orderedSame
            }) else { continue }
            if !result.contains(where: { $0 === person }) { result.append(person) }
        }
        return result
    }
}
