import Foundation
import UIKit

/// Everything a capture needs computed that ISN'T a SwiftData read/write:
/// on-device OCR, local parsing, AI extraction (with its offline fallback),
/// and person resolution/candidate ranking. Runs on its own actor, off the
/// main actor, so a slow OCR pass or a slow/hanging network request never
/// ties up `CaptureProcessor`'s main-actor work.
///
/// Everything in and out is a plain `Sendable` value type: `PersonSnapshot`
/// arrays and UUIDs, never a live `Person` or a `ModelContext`. The caller
/// (`CaptureProcessor`, on the main actor) takes a snapshot of whatever it
/// needs from SwiftData, awaits this actor, then does all mutation back on
/// the main actor using the returned IDs.
actor CaptureEngine {
    static let shared = CaptureEngine()

    struct Output: Sendable {
        var ocrText: String
        var effectiveText: String
        var localParse: CaptureParser.LocalParse
        var resolution: PersonResolver.Resolution
        var extraction: AIExtraction
        var usedLocalFallback: Bool
    }

    func analyze(
        rawText: String,
        transcript: String,
        imageURLs: [URL],
        capturedAt: Date,
        trustedIDs: [UUID],
        trustedNames: [String],
        eventName: String?,
        aliases: [String: String],
        existingFacts: [String],
        knownPeopleNames: [String],
        people: [PersonSnapshot]
    ) async -> Output {
        // 1. OCR any attached screenshots, entirely on-device. Best-effort:
        //    a failed or unreadable image just leaves `ocrText` empty; it
        //    never blocks the rest of the pipeline.
        var ocrText = ""
        if !imageURLs.isEmpty {
            var texts: [String] = []
            for url in imageURLs {
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
                if let text = try? await OCRService.recognizeText(in: image) {
                    texts.append(text)
                }
            }
            if !texts.isEmpty { ocrText = texts.joined(separator: "\n\n---\n\n") }
        }

        let effectiveText = [rawText, transcript, ocrText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !effectiveText.isEmpty else {
            return Output(
                ocrText: ocrText,
                effectiveText: "",
                localParse: CaptureParser.LocalParse(),
                resolution: PersonResolver.Resolution(),
                extraction: AIExtraction(),
                usedLocalFallback: false
            )
        }

        // 2. Local information first: type, date, sentiment, explicit
        //    reminders. Works fully offline and with no AI key configured.
        let localParse = CaptureParser.parse(effectiveText, reference: capturedAt, knownPeople: knownPeopleNames)

        // 3. Resolve people (first pass, before AI).
        var resolution = PersonResolver.resolve(
            text: effectiveText,
            trustedIDs: trustedIDs,
            trustedNames: trustedNames,
            aiMentioned: [],
            people: people
        )

        // 4. AI extraction (falls back to local heuristics internally if
        //    the configured provider fails for any reason).
        let extractionContext = AIExtractionContext(
            captureDate: capturedAt,
            timeZoneID: TimeZone.current.identifier,
            trustedPersonNames: trustedNames,
            aliases: aliases,
            eventName: eventName,
            existingFacts: existingFacts
        )
        let outcome = await AIExtractionCoordinator.extract(
            from: effectiveText,
            knownPeople: knownPeopleNames,
            context: extractionContext
        )
        var extraction = outcome.extraction

        // 5. Second resolution pass with the AI's mentioned names, in case
        //    it recognized someone the plain text scan missed.
        if resolution.matchedIDs.isEmpty && !extraction.peopleMentioned.isEmpty {
            resolution = PersonResolver.resolve(
                text: effectiveText,
                trustedIDs: trustedIDs,
                trustedNames: trustedNames,
                aiMentioned: extraction.peopleMentioned,
                people: people
            )
        }

        // 6. Safety net: if the provider left a fact/reminder/date
        //    unattributed, make one local, best-effort attempt to find the
        //    sentence it came from and attribute it from there. Never
        //    guesses beyond that; an item that still can't be traced back
        //    to a specific sentence stays unattributed.
        extraction = Self.reattributeIfNeeded(extraction, rawText: effectiveText, knownPeople: knownPeopleNames)

        return Output(
            ocrText: ocrText,
            effectiveText: effectiveText,
            localParse: localParse,
            resolution: resolution,
            extraction: extraction,
            usedLocalFallback: outcome.degraded
        )
    }

    // MARK: Attribution safety net

    private static func reattributeIfNeeded(_ extraction: AIExtraction, rawText: String, knownPeople: [String]) -> AIExtraction {
        guard !knownPeople.isEmpty else { return extraction }
        var result = extraction

        result.attributedFacts = extraction.attributedFacts.map { fact in
            guard fact.personNames.isEmpty else { return fact }
            var fact = fact
            fact.personNames = namesFor(value: fact.value, rawText: rawText, knownPeople: knownPeople)
            return fact
        }
        result.reminders = extraction.reminders.map { reminder in
            guard reminder.personNames.isEmpty else { return reminder }
            var reminder = reminder
            reminder.personNames = namesFor(value: reminder.title, rawText: rawText, knownPeople: knownPeople)
            return reminder
        }
        result.importantDates = extraction.importantDates.map { date in
            guard date.personNames.isEmpty else { return date }
            var date = date
            date.personNames = namesFor(value: date.display.isEmpty ? date.title : date.display, rawText: rawText, knownPeople: knownPeople)
            return date
        }
        return result
    }

    /// Finds the sentence in `rawText` that best matches `value` (an
    /// extracted, possibly-summarized fact/title) and returns which known
    /// people that specific sentence names. Falls back to an empty list
    /// (unattributed) rather than ever guessing.
    private static func namesFor(value: String, rawText: String, knownPeople: [String]) -> [String] {
        let sentences = rawText.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let needle = value.lowercased()
        guard let sentence = sentences.first(where: { sentence in
            let hay = sentence.lowercased()
            return hay.contains(needle) || needle.contains(hay) || sharesSignificantWords(hay, needle)
        }) else {
            return []
        }
        return CaptureParser.peopleNamed(in: sentence, knownPeople: knownPeople)
    }

    /// Loose overlap check for when the extracted value paraphrases the
    /// source sentence rather than quoting it verbatim.
    private static func sharesSignificantWords(_ a: String, _ b: String) -> Bool {
        let stop: Set<String> = ["the", "a", "an", "and", "to", "of", "in", "on", "for", "is", "are", "was", "were"]
        let wordsA = Set(a.split(separator: " ").map(String.init).filter { $0.count > 3 && !stop.contains($0) })
        let wordsB = Set(b.split(separator: " ").map(String.init).filter { $0.count > 3 && !stop.contains($0) })
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        return !wordsA.isDisjoint(with: wordsB)
    }
}
