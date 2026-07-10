import Foundation
import SwiftData
import UIKit

/// The central "organize it for me" pipeline. Captures are already safely
/// persisted (`CapturedMemory`, status `.queued`) before this ever runs;
/// this turns each one into exactly one interaction plus reminders, dates,
/// gift ideas, and evidence-linked `MemoryFact`s — or parks it in
/// Needs Context when the person can't be resolved confidently.
///
/// Isolation: bound to the main actor because it works on the shared
/// `ModelContainer.mainContext` (the same context every view uses, so
/// `@Query`-driven UI updates instantly). The AI/OCR work inside is all
/// `await`ed, so nothing here blocks the UI thread. An in-flight set plus
/// status transitions make processing idempotent across re-entry, retries,
/// and relaunches — processing the same capture twice never duplicates data.
@MainActor
final class CaptureProcessor {
    static let shared = CaptureProcessor()
    private init() {}

    private var context: ModelContext { AppServices.container.mainContext }
    /// Captures currently being worked on, so overlapping triggers
    /// (submission, app-active, manual retry) can't double-process one.
    private var inFlight: Set<UUID> = []

    private static let maxAttempts = 5

    // MARK: Entry points

    /// Called on app activation: pulls queued share-extension payloads in,
    /// re-queues captures a crash left stuck in `.processing`, then works
    /// through everything queued.
    func handleAppActivated() async {
        importSharedEntries()
        requeueStuckCaptures()
        await processQueued()
    }

    /// Processes every capture currently waiting in the queue.
    func processQueued() async {
        let queuedRaw = CaptureStatus.queued.rawValue
        let descriptor = FetchDescriptor<CapturedMemory>(
            predicate: #Predicate { $0.statusRaw == queuedRaw },
            sortBy: [SortDescriptor(\.capturedAt)]
        )
        guard let queued = try? context.fetch(descriptor) else { return }
        for capture in queued {
            await process(capture)
        }
    }

    /// Manual retry of a failed or stuck capture.
    func retry(_ capture: CapturedMemory) async {
        guard capture.status == .failed || capture.status == .needsContext || capture.status == .queued else { return }
        capture.errorMessage = ""
        capture.status = .queued
        await process(capture)
    }

    /// Resolves a Needs Context capture by trusting the given people, then
    /// reprocesses it immediately.
    func assign(people: [Person], to capture: CapturedMemory) async {
        for person in people where !capture.trustedPersonNames.contains(person.name) {
            capture.trustedPersonNames.append(person.name)
        }
        capture.status = .queued
        await process(capture)
    }

    // MARK: Core pipeline

    func process(_ capture: CapturedMemory) async {
        guard capture.status == .queued else { return }
        guard !inFlight.contains(capture.uuid) else { return }
        guard capture.attempts < Self.maxAttempts else {
            capture.status = .failed
            capture.errorMessage = "Gave up after \(Self.maxAttempts) attempts."
            save()
            return
        }
        inFlight.insert(capture.uuid)
        defer { inFlight.remove(capture.uuid) }

        capture.status = .processing
        capture.attempts += 1
        save()

        // 1. OCR any attached screenshots, locally, before anything else.
        if !capture.imagePaths.isEmpty && capture.ocrText.isEmpty {
            await runOCR(on: capture)
        }

        let text = capture.effectiveText
        guard !text.isEmpty else {
            capture.status = .failed
            capture.errorMessage = "Nothing readable was captured."
            save()
            return
        }

        // 2. Local information first: type, date, sentiment, explicit
        //    reminders. Works offline and with no key configured.
        let localParse = CaptureParser.parse(text, reference: capture.capturedAt)

        // 3. Resolve people.
        let allPeople = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        var resolution = PersonResolver.resolve(
            text: text,
            trustedNames: capture.trustedPersonNames,
            aiMentioned: [],
            people: allPeople
        )

        // 4. AI extraction (falls back to local heuristics internally).
        let extractionContext = AIExtractionContext(
            captureDate: capture.capturedAt,
            timeZoneID: TimeZone.current.identifier,
            trustedPersonNames: capture.trustedPersonNames,
            aliases: aliasMap(for: resolution.matched),
            eventName: capture.eventName.isEmpty ? nil : capture.eventName,
            existingFacts: existingFactDigest(for: resolution.matched)
        )
        let outcome = await AIExtractionCoordinator.extract(
            from: text,
            knownPeople: allPeople.map(\.name),
            context: extractionContext
        )
        let extraction = outcome.extraction
        capture.usedLocalFallback = outcome.degraded

        // 5. Second resolution pass with the AI's mentioned names, in case
        //    it recognized someone the plain text scan missed.
        if resolution.matched.isEmpty && !extraction.peopleMentioned.isEmpty {
            resolution = PersonResolver.resolve(
                text: text,
                trustedNames: capture.trustedPersonNames,
                aiMentioned: extraction.peopleMentioned,
                people: allPeople
            )
        }

        capture.inferenceConfidence = resolution.confidence
        capture.candidatePersonNames = resolution.candidates.map(\.person.name)

        // 6. No confident person → park in Needs Context. The capture (and
        //    everything parsed so far) is preserved; assignment re-runs this
        //    whole pipeline with the person trusted.
        guard !resolution.matched.isEmpty else {
            capture.resolvedPersonNames = []
            capture.status = .needsContext
            capture.title = "Who was this with?"
            capture.detail = capture.preview
            save()
            return
        }

        let people = resolution.matched
        capture.resolvedPersonNames = people.map(\.name)

        // 7. Create (or find) the one interaction this capture produces.
        let interaction = findOrCreateInteraction(
            for: capture,
            people: people,
            localParse: localParse,
            extraction: extraction
        )

        // 8. Explicit reminders, evidence-linked facts, gifts, dates.
        var createdReminderDates: [Date] = []
        applyReminders(from: extraction, localParse: localParse, capture: capture, people: people, createdDueDates: &createdReminderDates)
        applyFacts(from: extraction, capture: capture, people: people, interaction: interaction)
        applyGiftIdeas(from: extraction, capture: capture, people: people)
        applyImportantDates(from: extraction, capture: capture, people: people)

        // 9. Done. Compose the feed presentation and finish.
        capture.title = feedTitle(for: capture, people: people, interaction: interaction)
        capture.detail = feedDetail(extraction: extraction, reminderDates: createdReminderDates)
        capture.errorMessage = ""
        capture.status = .processed
        save()
    }

    // MARK: OCR

    private func runOCR(on capture: CapturedMemory) async {
        var texts: [String] = []
        for url in capture.imageURLs() {
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { continue }
            if let text = try? await OCRService.recognizeText(in: image) {
                texts.append(text)
            }
        }
        if !texts.isEmpty {
            capture.ocrText = texts.joined(separator: "\n\n---\n\n")
        }
        // OCR failure is not fatal: the capture may still carry raw text,
        // and if it doesn't, the empty-text guard downstream marks it
        // failed with a clear message instead of blocking anything.
    }

    // MARK: Interaction

    /// Finds the interaction a previous (crashed/duplicated) run already
    /// created for this capture, or creates exactly one.
    private func findOrCreateInteraction(
        for capture: CapturedMemory,
        people: [Person],
        localParse: CaptureParser.LocalParse,
        extraction: AIExtraction
    ) -> Interaction {
        if let existing = Self.interaction(for: capture, context: context) {
            // Idempotent re-run: keep the existing record, just make sure
            // its people are attached (a crash could land between insert
            // and linking).
            if existing.people.isEmpty { existing.people = people }
            return existing
        }

        // Type: entry-point hint → local parse → AI inference → sane default.
        let aiType = extraction.inferredInteractionType.flatMap { InteractionType(rawValue: $0) }
        let type = capture.typeHint
            ?? localParse.interactionType
            ?? (extraction.confidence(for: "type") >= 0.6 ? aiType : nil)
            ?? (capture.eventName.isEmpty ? .inPerson : .event)

        // Date: trusted event date → clearly-stated date → capture time.
        let aiDate = extraction.confidence(for: "date") >= 0.7 ? extraction.inferredDate : nil
        let date = capture.eventDate ?? localParse.interactionDate ?? aiDate ?? capture.capturedAt

        // Quality: neutral unless the user explicitly said how it went.
        // Never moved by the AI merely thinking it "sounded positive".
        let aiSentiment: Sentiment? = {
            guard extraction.confidence(for: "sentiment") >= 0.75 else { return nil }
            switch extraction.explicitSentiment {
            case "bad": return .bad
            case "good": return .good
            case "great": return .great
            case "neutral": return .neutral
            default: return nil
            }
        }()
        let sentiment = localParse.explicitSentiment ?? aiSentiment ?? .neutral

        let interaction = Interaction(
            type: type,
            date: date,
            location: capture.eventLocation,
            note: capture.effectiveText,
            topics: extraction.topics,
            quality: sentiment.quality,
            messageSummary: extraction.summary
        )
        interaction.sourceCaptureUUID = capture.uuid
        if capture.source == .share || capture.source == .photo {
            interaction.isImported = true
            interaction.rawImportText = capture.effectiveText
        }
        // Closeness impact (zero for neutral) is recorded per person on the
        // interaction itself, so undo reverses exactly what was applied.
        InteractionSaver.finalize(interaction, people: people, context: context)

        // The extraction record, approved or not, for provenance display.
        let summary = ConversationSummary(extraction: extraction)
        summary.interaction = interaction
        context.insert(summary)

        return interaction
    }

    // MARK: Reminders

    private func applyReminders(
        from extraction: AIExtraction,
        localParse: CaptureParser.LocalParse,
        capture: CapturedMemory,
        people: [Person],
        createdDueDates: inout [Date]
    ) {
        guard let first = people.first else { return }

        // Merge AI + local explicit reminders, deduplicated by title.
        var explicit: [(title: String, dueDate: Date?)] = extraction.reminders.map { ($0.title, $0.dueDate) }
        for local in localParse.reminders {
            if !explicit.contains(where: { $0.title.caseInsensitiveCompare(local.title) == .orderedSame }) {
                explicit.append(local)
            }
        }

        for item in explicit {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            // Idempotency + "a reminder already exists": skip duplicates by
            // capture stamp or by an equal open reminder for this person.
            if reminderExists(title: title, for: first, captureUUID: capture.uuid) { continue }
            // Resolve relative dates against the *capture* date; leave a
            // reasonable default only for explicit instructions with no
            // resolvable day at all.
            let due = item.dueDate
                ?? CaptureParser.resolveRelativeDate(in: title, reference: capture.capturedAt)
                ?? Calendar.current.date(byAdding: .day, value: 3, to: capture.capturedAt)
                ?? capture.capturedAt
            let reminder = Reminder(title: title, dueDate: due, type: .followUp, person: first)
            reminder.sourceCaptureUUID = capture.uuid
            context.insert(reminder)
            NotificationService.shared.schedule(reminder: reminder)
            createdDueDates.append(due)
        }

        // Implied follow-ups are stored as suggestions, never scheduled.
        for implied in extraction.impliedFollowUps {
            let value = implied.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            insertFactIfNew(type: .commitment, value: value, person: first,
                            confidence: extraction.confidence(for: "reminders") * 0.7,
                            status: .suggested, capture: capture)
        }
    }

    private func reminderExists(title: String, for person: Person, captureUUID: UUID) -> Bool {
        person.reminders.contains {
            ($0.sourceCaptureUUID == captureUUID && $0.title.caseInsensitiveCompare(title) == .orderedSame)
                || (!$0.completed && $0.title.caseInsensitiveCompare(title) == .orderedSame)
        }
    }

    // MARK: Facts

    private func applyFacts(
        from extraction: AIExtraction,
        capture: CapturedMemory,
        people: [Person],
        interaction: Interaction
    ) {
        // Single-person captures attach facts to that person; multi-person
        // captures attach only clearly-shared facts to the first person is
        // wrong — so for multiple people, facts still go to the first
        // (primary) person, which matches how the note reads in practice
        // ("Met Daniel and Priya… Daniel is joining the robotics club" —
        // imperfect attribution is why facts stay reviewable and rejectable).
        guard let primary = people.first else { return }

        func add(_ values: [String], _ type: MemoryFactType, field: String) {
            let confidence = extraction.confidence(for: field)
            let status: MemoryFactStatus = confidence >= 0.75 ? .active : .suggested
            for value in values {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                insertFactIfNew(type: type, value: trimmed, person: primary,
                                confidence: confidence, status: status, capture: capture)
            }
        }

        add(extraction.interests, .interest, field: "interests")
        add(extraction.dislikes, .dislike, field: "interests")
        add(extraction.schoolOrWorkFacts, .schoolOrWork, field: "interests")
        add(extraction.locationFacts, .location, field: "interests")
        add(extraction.familyFacts, .family, field: "interests")
        add(extraction.personalityNotes, .personality, field: "interests")
    }

    /// Inserts a fact unless an equivalent one already exists for this
    /// person (any status — a rejected fact must never resurrect itself on
    /// reprocessing) or the value duplicates a manually-entered field.
    private func insertFactIfNew(
        type: MemoryFactType,
        value: String,
        person: Person,
        confidence: Double,
        status: MemoryFactStatus,
        capture: CapturedMemory,
        dateValue: Date? = nil
    ) {
        let exists = person.memoryFacts.contains {
            $0.type == type && $0.value.caseInsensitiveCompare(value) == .orderedSame
        }
        guard !exists else { return }
        // Don't duplicate what the user already typed by hand.
        switch type {
        case .interest where person.interests.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }):
            return
        case .dislike where person.dislikes.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }):
            return
        case .schoolOrWork where !person.schoolOrWork.isEmpty && value.localizedCaseInsensitiveContains(person.schoolOrWork):
            return
        default:
            break
        }
        let fact = MemoryFact(
            type: type,
            value: value,
            person: person,
            confidence: confidence,
            status: status,
            dateValue: dateValue,
            sourceCaptureUUID: capture.uuid
        )
        context.insert(fact)
    }

    // MARK: Gifts

    private func applyGiftIdeas(from extraction: AIExtraction, capture: CapturedMemory, people: [Person]) {
        guard let primary = people.first else { return }
        for idea in extraction.giftIdeas {
            let title = idea.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            guard !primary.giftIdeas.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else { continue }
            let gift = GiftIdea(title: title, person: primary, notes: "From capture on \(capture.capturedAt.shortFormat)")
            gift.sourceCaptureUUID = capture.uuid
            context.insert(gift)
        }
    }

    // MARK: Important dates

    private func applyImportantDates(from extraction: AIExtraction, capture: CapturedMemory, people: [Person]) {
        guard let primary = people.first else { return }
        let confidence = extraction.confidence(for: "importantDates")
        for extracted in extraction.importantDates {
            guard let dateValue = extracted.date else {
                // Incomplete/uncertain date: keep it as a suggestion, never
                // invent a year, month, or day.
                let display = extracted.display.isEmpty ? extracted.title : extracted.display
                if !display.isEmpty {
                    insertFactIfNew(type: .importantDate, value: display, person: primary,
                                    confidence: confidence, status: .suggested, capture: capture)
                }
                continue
            }
            guard confidence >= 0.6 else {
                insertFactIfNew(type: .importantDate, value: extracted.display, person: primary,
                                confidence: confidence, status: .suggested, capture: capture,
                                dateValue: dateValue)
                continue
            }
            if extracted.title == "Birthday", primary.birthday == nil {
                primary.birthday = dateValue
                NotificationService.shared.scheduleBirthday(for: primary)
                continue
            }
            let sameDay = primary.importantDates.contains {
                $0.title.caseInsensitiveCompare(extracted.title) == .orderedSame
                    && Calendar.current.isDate($0.date, equalTo: dateValue, toGranularity: .day)
            }
            guard !sameDay else { continue }
            let record = ImportantDate(title: extracted.title, date: dateValue, person: primary)
            record.sourceCaptureUUID = capture.uuid
            context.insert(record)
            NotificationService.shared.schedule(importantDate: record)
        }
    }

    // MARK: Feed presentation

    private func feedTitle(for capture: CapturedMemory, people: [Person], interaction: Interaction) -> String {
        let names = people.map(\.firstName).joined(separator: " & ")
        let firstSentence = capture.effectiveText
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstSentence.isEmpty && firstSentence.count <= 60 {
            return firstSentence.capitalizedFirst
        }
        return "\(interaction.type.label) with \(names)"
    }

    private func feedDetail(extraction: AIExtraction, reminderDates: [Date]) -> String {
        var parts: [String] = []
        let facts = (extraction.schoolOrWorkFacts + extraction.locationFacts + extraction.interests).prefix(2)
        if !facts.isEmpty {
            parts.append(facts.joined(separator: ", "))
        } else if !extraction.topics.isEmpty {
            parts.append(extraction.topics.prefix(3).joined(separator: ", "))
        }
        if let firstDue = reminderDates.first {
            let day = firstDue.formatted(.dateTime.weekday(.wide))
            parts.append(reminderDates.count == 1
                         ? "reminder created for \(day)"
                         : "\(reminderDates.count) reminders created")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Undo

    /// Reverses everything this capture produced: the interaction (and its
    /// closeness/last-contacted effects), reminders, important dates, gift
    /// ideas, and memory facts — found by their explicit `sourceCaptureUUID`
    /// stamp, never by guessing from titles or dates.
    func undo(_ capture: CapturedMemory) {
        let target: UUID? = capture.uuid

        if let interaction = Self.interaction(for: capture, context: context) {
            let people = interaction.people
            InteractionSaver.reverseClosenessImpact(of: interaction)
            context.delete(interaction)
            for person in people { person.recomputeContactDates() }
        }
        if let reminders = try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.sourceCaptureUUID == target })) {
            for reminder in reminders {
                NotificationService.shared.cancel(reminder: reminder)
                context.delete(reminder)
            }
        }
        if let dates = try? context.fetch(FetchDescriptor<ImportantDate>(predicate: #Predicate { $0.sourceCaptureUUID == target })) {
            for date in dates {
                NotificationService.shared.cancel(importantDate: date)
                context.delete(date)
            }
        }
        if let gifts = try? context.fetch(FetchDescriptor<GiftIdea>(predicate: #Predicate { $0.sourceCaptureUUID == target })) {
            for gift in gifts { context.delete(gift) }
        }
        if let facts = try? context.fetch(FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.sourceCaptureUUID == target })) {
            for fact in facts { context.delete(fact) }
        }
        capture.status = .dismissed
        capture.detail = "All changes undone"
        save()
    }

    /// Deletes the capture record itself (leaving anything it created in
    /// place — use `undo` first for a full reversal) plus its image files.
    func delete(_ capture: CapturedMemory) {
        for url in capture.imageURLs() {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(capture)
        save()
    }

    // MARK: Lookups shared with the UI

    static func interaction(for capture: CapturedMemory, context: ModelContext) -> Interaction? {
        let target: UUID? = capture.uuid
        let descriptor = FetchDescriptor<Interaction>(predicate: #Predicate { $0.sourceCaptureUUID == target })
        return (try? context.fetch(descriptor))?.first
    }

    static func facts(for capture: CapturedMemory, context: ModelContext) -> [MemoryFact] {
        let target: UUID? = capture.uuid
        let descriptor = FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.sourceCaptureUUID == target })
        return (try? context.fetch(descriptor)) ?? []
    }

    static func reminders(for capture: CapturedMemory, context: ModelContext) -> [Reminder] {
        let target: UUID? = capture.uuid
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.sourceCaptureUUID == target })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Share-extension ingestion

    /// Imports every payload the Share Extension queued into durable
    /// `CapturedMemory` records. Each entry is removed from the App Group
    /// queue only *after* its SwiftData record has been persisted, so a
    /// crash mid-import re-imports (idempotently, by shared UUID) instead
    /// of losing anything.
    func importSharedEntries() {
        let pending = SharedImportInbox.pending()
        guard !pending.isEmpty else { return }
        let existingUUIDs = Set(((try? context.fetch(FetchDescriptor<CapturedMemory>())) ?? []).map(\.uuid))

        for entry in pending {
            if existingUUIDs.contains(entry.id) {
                // Already imported on a previous pass that crashed before
                // removing the queue entry: just clean up.
                SharedImportInbox.remove(entry.id)
                continue
            }
            // Move shared images from the App Group container into the
            // app's own sandbox so they survive queue cleanup.
            var localImageNames: [String] = []
            for name in entry.imageFileNames {
                guard let sourceDir = SharedImportInbox.imagesDirectory else { continue }
                let source = sourceDir.appendingPathComponent(name)
                let destination = CapturedMemory.imagesDirectory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.copyItem(at: source, to: destination)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    localImageNames.append(name)
                }
            }
            let capture = CapturedMemory(
                rawText: entry.text,
                source: entry.imageFileNames.isEmpty ? .share : .photo,
                imagePaths: localImageNames,
                capturedAt: entry.receivedAt
            )
            capture.uuid = entry.id
            context.insert(capture)
            do {
                try context.save()
                SharedImportInbox.remove(entry.id, deletingImages: true)
            } catch {
                // Leave the entry queued; it will be retried next activation.
                context.delete(capture)
            }
        }
    }

    /// Re-queues captures a crash or kill left stuck mid-`processing`.
    private func requeueStuckCaptures() {
        let processingRaw = CaptureStatus.processing.rawValue
        let descriptor = FetchDescriptor<CapturedMemory>(predicate: #Predicate { $0.statusRaw == processingRaw })
        guard let stuck = try? context.fetch(descriptor) else { return }
        for capture in stuck where !inFlight.contains(capture.uuid) {
            capture.status = .queued
        }
        if !stuck.isEmpty { save() }
    }

    // MARK: Helpers

    private func aliasMap(for people: [Person]) -> [String: String] {
        var map: [String: String] = [:]
        for person in people where !person.nickname.isEmpty && person.nickname != person.name {
            map[person.nickname] = person.name
        }
        return map
    }

    private func existingFactDigest(for people: [Person]) -> [String] {
        var digest: [String] = []
        for person in people {
            digest.append(contentsOf: person.combinedInterests.map { "\(person.firstName) likes \($0)" })
            digest.append(contentsOf: person.visibleFacts.prefix(10).map { "\(person.firstName): \($0.value)" })
        }
        return digest
    }

    private func save() {
        try? context.save()
    }
}
