import Foundation
import SwiftData

/// The central "organize it for me" pipeline. Captures are already safely
/// persisted (`CapturedMemory`, status `.queued`) before this ever runs;
/// this turns each one into exactly one interaction plus reminders, dates,
/// gift ideas, and evidence-linked `MemoryFact`s, or parks it in
/// Needs Context when the person can't be resolved confidently.
///
/// Concurrency: this class is deliberately NOT globally `@MainActor`. Only
/// the methods that actually touch `ModelContext`/SwiftData models are
/// marked `@MainActor`; the OCR, local parsing, AI extraction, and
/// candidate-ranking work happen inside `CaptureEngine`, a separate actor
/// that only ever sees `Sendable` value types (never a live `Person` or a
/// `ModelContext`). `process(_:)` gathers a `Sendable` snapshot of what it
/// needs on the main actor, `await`s `CaptureEngine` (which genuinely runs
/// off the main actor), then does every mutation back on the main actor
/// with the returned IDs. An in-flight set plus status transitions make
/// processing idempotent across re-entry, retries, and relaunches;
/// processing the same capture twice never duplicates data.
final class CaptureProcessor {
    static let shared = CaptureProcessor()
    private init() {}

    @MainActor private var context: ModelContext { AppServices.container.mainContext }
    /// Captures currently being worked on, so overlapping triggers
    /// (submission, app-active, manual retry) can't double-process one.
    @MainActor private var inFlight: Set<UUID> = []

    private static let maxAttempts = 5

    // MARK: Durable persistence

    /// Inserts and saves a brand-new capture. Returns `nil` on success, or
    /// a clean user-facing message on failure. The capture is only ever
    /// durable once this returns `nil`; every call site (Quick Capture,
    /// voice, App Intents, share-extension import) must check this before
    /// giving haptic/dismiss/toast feedback or enqueuing processing; on
    /// failure the half-inserted object is rolled back so a retry can
    /// never produce a duplicate.
    @MainActor
    @discardableResult
    func persistNewCapture(_ capture: CapturedMemory) -> String? {
        context.insert(capture)
        do {
            try context.save()
            return nil
        } catch {
            context.delete(capture)
            return "Couldn't save this capture. Check available storage and try again."
        }
    }

    // MARK: Entry points

    /// Called on app activation: pulls queued share-extension payloads in,
    /// re-queues captures a crash left stuck in `.processing`, then works
    /// through everything queued.
    func handleAppActivated() async {
        await importSharedEntries()
        await requeueStuckCaptures()
        await processQueued()
    }

    /// Processes every capture currently waiting in the queue.
    @MainActor
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
    @MainActor
    func retry(_ capture: CapturedMemory) async {
        guard capture.status == .failed || capture.status == .needsContext || capture.status == .queued else { return }
        capture.errorMessage = ""
        capture.status = .queued
        await process(capture)
    }

    /// Resolves a Needs Context capture by trusting the given people, then
    /// reprocesses it immediately.
    @MainActor
    func assign(people: [Person], to capture: CapturedMemory) async {
        for person in people {
            if !capture.trustedPersonIDs.contains(person.uuid) {
                capture.trustedPersonIDs.append(person.uuid)
            }
            if !capture.trustedPersonNames.contains(person.name) {
                capture.trustedPersonNames.append(person.name)
            }
        }
        capture.status = .queued
        await process(capture)
    }

    // MARK: Core pipeline

    @MainActor
    func process(_ capture: CapturedMemory, in suppliedContext: ModelContext? = nil) async {
        let processingContext = suppliedContext ?? context
        guard capture.status == .queued else { return }
        guard !inFlight.contains(capture.uuid) else { return }
        guard capture.attempts < Self.maxAttempts else {
            capture.status = .failed
            capture.errorMessage = "Gave up after \(Self.maxAttempts) attempts."
            save(processingContext)
            return
        }
        inFlight.insert(capture.uuid)
        defer { inFlight.remove(capture.uuid) }

        capture.status = .processing
        capture.attempts += 1
        save(processingContext)

        // Gather everything CaptureEngine needs as plain Sendable values;
        // no live Person, no ModelContext crosses into it.
        let allPeople = (try? processingContext.fetch(FetchDescriptor<Person>())) ?? []
        let snapshots = allPeople.map { person in
            PersonSnapshot(
                id: person.uuid,
                name: person.name,
                nickname: person.nickname,
                firstName: person.firstName,
                contactMethodValues: person.contactMethods.map(\.value),
                lastContactedAt: person.lastContactedAt,
                isArchived: person.isArchived
            )
        }
        let trustedPeopleNow = CapturedMemory.resolvePeople(ids: capture.trustedPersonIDs, in: allPeople)
        let aliases = aliasMap(for: trustedPeopleNow)
        let existingFacts = existingFactDigest(for: trustedPeopleNow)

        let output = await CaptureEngine.shared.analyze(
            rawText: capture.rawText,
            transcript: capture.transcript,
            imageURLs: capture.imageURLs(),
            capturedAt: capture.capturedAt,
            trustedIDs: capture.trustedPersonIDs,
            trustedNames: capture.trustedPersonNames,
            eventName: capture.eventName.isEmpty ? nil : capture.eventName,
            aliases: aliases,
            existingFacts: existingFacts,
            knownPeopleNames: allPeople.map(\.name),
            people: snapshots
        )

        if !output.ocrText.isEmpty { capture.ocrText = output.ocrText }

        guard !output.effectiveText.isEmpty else {
            capture.status = .failed
            capture.errorMessage = "Nothing readable was captured."
            save(processingContext)
            return
        }

        let extraction = output.extraction
        let localParse = output.localParse
        capture.usedLocalFallback = output.usedLocalFallback
        capture.inferenceConfidence = output.resolution.confidence
        capture.candidatePersonIDs = output.resolution.candidates.map(\.personID)
        capture.candidatePersonNames = CapturedMemory.resolvePeople(ids: capture.candidatePersonIDs, in: allPeople).map(\.name)

        // No confident person → park in Needs Context. The capture (and
        // everything parsed so far) is preserved; assignment re-runs this
        // whole pipeline with the person trusted.
        guard !output.resolution.matchedIDs.isEmpty else {
            capture.resolvedPersonIDs = []
            capture.resolvedPersonNames = []
            capture.status = .needsContext
            capture.title = "Who was this with?"
            capture.detail = capture.preview
            save(processingContext)
            return
        }

        let people = CapturedMemory.resolvePeople(ids: output.resolution.matchedIDs, in: allPeople)
        guard !people.isEmpty else {
            // Every matched ID resolved to a person that's since been
            // deleted; treat exactly like no match at all.
            capture.resolvedPersonIDs = []
            capture.resolvedPersonNames = []
            capture.status = .needsContext
            capture.title = "Who was this with?"
            capture.detail = capture.preview
            save(processingContext)
            return
        }
        capture.resolvedPersonIDs = people.map(\.uuid)
        capture.resolvedPersonNames = people.map(\.name)

        // Create (or find) the one interaction this capture produces.
        let interaction = findOrCreateInteraction(
            for: capture,
            people: people,
            localParse: localParse,
            extraction: extraction,
            context: processingContext
        )

        // Explicit reminders (scheduled or unscheduled-suggestion),
        // evidence-linked facts, gift ideas, important dates: every one
        // individually attributed, never defaulted to `people.first`.
        var createdReminderDates: [Date] = []
        applyReminders(from: extraction, localParse: localParse, capture: capture, interaction: interaction, people: people, createdDueDates: &createdReminderDates, context: processingContext)
        applyFacts(from: extraction, capture: capture, interaction: interaction, people: people, context: processingContext)
        applyGiftIdeas(from: extraction, capture: capture, interaction: interaction, people: people, context: processingContext)
        applyImportantDates(from: extraction, capture: capture, interaction: interaction, people: people, context: processingContext)

        // Done. Compose the feed presentation and finish.
        capture.title = feedTitle(for: capture, people: people, interaction: interaction)
        capture.detail = feedDetail(extraction: extraction, reminderDates: createdReminderDates)
        capture.errorMessage = ""
        capture.status = .processed
        save(processingContext)
    }

    // MARK: Interaction

    /// Finds the interaction a previous (crashed/duplicated) run already
    /// created for this capture, or creates exactly one.
    @MainActor
    private func findOrCreateInteraction(
        for capture: CapturedMemory,
        people: [Person],
        localParse: CaptureParser.LocalParse,
        extraction: AIExtraction,
        context: ModelContext
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

    // MARK: Attribution

    /// Matches AI/local-reported names against THIS capture's own resolved
    /// people, never the whole database, so an item is attached to
    /// exactly the person(s) actually named for it. Zero matches means
    /// unattributed; more than one means the fact genuinely names several
    /// people together.
    private func matchAttributed(_ names: [String], among people: [Person]) -> [Person] {
        guard !names.isEmpty else { return [] }
        var matched: [Person] = []
        for name in names {
            guard let person = people.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    || (!$0.nickname.isEmpty && $0.nickname.caseInsensitiveCompare(name) == .orderedSame)
                    || $0.firstName.caseInsensitiveCompare(name) == .orderedSame
            }) else { continue }
            if !matched.contains(where: { $0 === person }) { matched.append(person) }
        }
        return matched
    }

    // MARK: Reminders

    @MainActor
    private func applyReminders(
        from extraction: AIExtraction,
        localParse: CaptureParser.LocalParse,
        capture: CapturedMemory,
        interaction: Interaction,
        people: [Person],
        createdDueDates: inout [Date],
        context: ModelContext
    ) {
        // Merge AI + local explicit reminders, deduplicated by title.
        var explicit: [(title: String, dueDate: Date?, personNames: [String])] = extraction.reminders.map { ($0.title, $0.dueDate, $0.personNames) }
        for local in localParse.reminders {
            if !explicit.contains(where: { $0.title.caseInsensitiveCompare(local.title) == .orderedSame }) {
                explicit.append(local)
            }
        }

        let existingReminders = Self.reminders(for: capture, context: context)
        let existingSuggestions = Self.facts(for: capture, context: context).filter { $0.type == .reminderSuggestion }
        // Tracks titles inserted during THIS run too, not just what's
        // already in the database; guards against the extraction itself
        // (an AI response, in particular) containing a repeated item in a
        // single pass, which a DB-only check taken once up front wouldn't catch.
        var insertedReminderTitles = Set(existingReminders.map { $0.title.lowercased() })
        var insertedSuggestionTitles = Set(existingSuggestions.map { $0.value.lowercased() })

        for item in explicit {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let attributed = matchAttributed(item.personNames, among: people)
            let owner = attributed.count == 1 ? attributed.first : nil
            let titleKey = title.lowercased()

            if capture.source == .instagram {
                // A contact mentioning a deadline in a DM is not the same
                // thing as the user asking Social Climber to schedule a
                // reminder. Keep it reviewable as a suggestion instead of
                // creating an open loop or notification automatically.
                guard !insertedSuggestionTitles.contains(titleKey) else { continue }
                let fact = MemoryFact(
                    type: .reminderSuggestion,
                    value: title,
                    person: owner,
                    confidence: extraction.confidence(for: "reminders"),
                    status: .suggested,
                    dateValue: item.dueDate,
                    sourceCaptureUUID: capture.uuid,
                    sourceInteractionUUID: interaction.uuid
                )
                context.insert(fact)
                insertedSuggestionTitles.insert(titleKey)
            } else if let due = item.dueDate {
                // Explicit instruction + resolvable date → a real,
                // scheduled reminder. Never invents a date otherwise.
                guard !insertedReminderTitles.contains(titleKey) else { continue }
                guard !anyOpenReminderDuplicate(title: title, context: context) else { continue }
                let reminder = Reminder(title: title, dueDate: due, type: .followUp, person: owner)
                reminder.sourceCaptureUUID = capture.uuid
                context.insert(reminder)
                NotificationService.shared.schedule(reminder: reminder)
                createdDueDates.append(due)
                insertedReminderTitles.insert(titleKey)
            } else {
                // Explicit instruction, no resolvable date → an unscheduled
                // reminder suggestion the user can later give a date.
                guard !insertedSuggestionTitles.contains(titleKey) else { continue }
                let fact = MemoryFact(
                    type: .reminderSuggestion,
                    value: title,
                    person: owner,
                    confidence: extraction.confidence(for: "reminders"),
                    status: .suggested,
                    sourceCaptureUUID: capture.uuid,
                    sourceInteractionUUID: interaction.uuid
                )
                context.insert(fact)
                insertedSuggestionTitles.insert(titleKey)
            }
        }

        // Implied follow-ups are stored as suggestions, never scheduled,
        // and never attributed (the text didn't explicitly say who).
        let existingImplied = Self.facts(for: capture, context: context).filter { $0.type == .commitment }
        var insertedImplied = Set(existingImplied.map { $0.value.lowercased() })
        for implied in extraction.impliedFollowUps {
            let value = implied.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = value.lowercased()
            guard !insertedImplied.contains(key) else { continue }
            let fact = MemoryFact(
                type: .commitment,
                value: value,
                person: nil,
                confidence: extraction.confidence(for: "reminders") * 0.7,
                status: .suggested,
                sourceCaptureUUID: capture.uuid,
                sourceInteractionUUID: interaction.uuid
            )
            context.insert(fact)
            insertedImplied.insert(key)
        }
    }

    /// A reminder already exists somewhere with this exact open title;
    /// belt-and-suspenders against creating a near-duplicate reminder the
    /// user (or a different capture) already has pending.
    private func anyOpenReminderDuplicate(title: String, context: ModelContext) -> Bool {
        let all = (try? context.fetch(FetchDescriptor<Reminder>())) ?? []
        return all.contains { !$0.completed && $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    // MARK: Facts

    @MainActor
    private func applyFacts(
        from extraction: AIExtraction,
        capture: CapturedMemory,
        interaction: Interaction,
        people: [Person],
        context: ModelContext
    ) {
        var existing = Self.facts(for: capture, context: context)

        func add(_ items: [ExtractedFact], _ type: MemoryFactType, field: String) {
            let confidence = extraction.confidence(for: field)
            // A DM export is third-party conversation evidence, not an
            // instruction to edit someone's profile. Even high-confidence
            // Instagram facts remain suggestions until the user confirms
            // them; other capture sources keep the normal confidence rule.
            let status: MemoryFactStatus = capture.source == .instagram
                ? .suggested
                : (confidence >= 0.75 ? .active : .suggested)
            for item in items {
                let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let attributed = matchAttributed(item.personNames, among: people)
                insertFact(type: type, value: value, people: attributed, confidence: confidence, status: status,
                           capture: capture, interaction: interaction, existing: &existing, context: context)
            }
        }

        add(extraction.attributedFacts(ofType: .interest), .interest, field: "interests")
        add(extraction.attributedFacts(ofType: .dislike), .dislike, field: "interests")
        add(extraction.attributedFacts(ofType: .schoolOrWork), .schoolOrWork, field: "interests")
        add(extraction.attributedFacts(ofType: .location), .location, field: "interests")
        add(extraction.attributedFacts(ofType: .family), .family, field: "interests")
        add(extraction.attributedFacts(ofType: .personality), .personality, field: "interests")
    }

    /// Inserts a fact for each attributed person (fanning out when several
    /// people are confidently named together), or a single unattributed
    /// fact when no one is named, never `people.first`. Skips a value
    /// that already exists for this capture with the same type and
    /// attribution (any status: a rejected or reassigned fact must never
    /// resurrect on reprocessing), and skips one that duplicates a
    /// manually-entered profile field. `existing` is `inout` and updated
    /// with every fact this call inserts, so a second item in the same
    /// extraction pass (not just a second processing run) can't duplicate
    /// the first.
    @MainActor
    private func insertFact(
        type: MemoryFactType,
        value: String,
        people: [Person],
        confidence: Double,
        status: MemoryFactStatus,
        capture: CapturedMemory,
        interaction: Interaction?,
        existing: inout [MemoryFact],
        dateValue: Date? = nil,
        context: ModelContext
    ) {
        func alreadyExists(person: Person?) -> Bool {
            existing.contains {
                $0.type == type
                    && $0.value.caseInsensitiveCompare(value) == .orderedSame
                    && $0.person?.persistentModelID == person?.persistentModelID
            }
        }
        func duplicatesManualField(_ person: Person) -> Bool {
            switch type {
            case .interest: return person.interests.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            case .dislike: return person.dislikes.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            case .schoolOrWork: return !person.schoolOrWork.isEmpty && value.localizedCaseInsensitiveContains(person.schoolOrWork)
            default: return false
            }
        }

        if people.isEmpty {
            guard !alreadyExists(person: nil) else { return }
            let fact = MemoryFact(
                type: type, value: value, person: nil, confidence: confidence, status: status,
                dateValue: dateValue, sourceCaptureUUID: capture.uuid, sourceInteractionUUID: interaction?.uuid
            )
            context.insert(fact)
            existing.append(fact)
            return
        }

        for person in people {
            guard !duplicatesManualField(person), !alreadyExists(person: person) else { continue }
            let fact = MemoryFact(
                type: type, value: value, person: person, confidence: confidence, status: status,
                dateValue: dateValue, sourceCaptureUUID: capture.uuid, sourceInteractionUUID: interaction?.uuid
            )
            context.insert(fact)
            existing.append(fact)
        }
    }

    // MARK: Gifts

    @MainActor
    private func applyGiftIdeas(from extraction: AIExtraction, capture: CapturedMemory, interaction: Interaction, people: [Person], context: ModelContext) {
        var existingFacts = Self.facts(for: capture, context: context)
        var insertedGiftKeys = Set<String>()
        for item in extraction.attributedFacts(ofType: .giftIdea) {
            let title = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let attributed = matchAttributed(item.personNames, among: people)

            if attributed.isEmpty {
                // Unattributed gift ideas stay inspectable/assignable
                // rather than becoming an orphaned, invisible GiftIdea.
                let key = "unattributed|\(title.lowercased())"
                guard !insertedGiftKeys.contains(key),
                      !existingFacts.contains(where: { $0.type == .giftIdea && $0.value.caseInsensitiveCompare(title) == .orderedSame && $0.person == nil })
                else { continue }
                let fact = MemoryFact(
                    type: .giftIdea, value: title, person: nil,
                    confidence: extraction.confidence(for: "interests"), status: .suggested,
                    sourceCaptureUUID: capture.uuid, sourceInteractionUUID: interaction.uuid
                )
                context.insert(fact)
                existingFacts.append(fact)
                insertedGiftKeys.insert(key)
                continue
            }
            for person in attributed {
                let key = "\(person.persistentModelID)|\(title.lowercased())"
                guard !insertedGiftKeys.contains(key),
                      !person.giftIdeas.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
                else { continue }
                if capture.source == .instagram {
                    let fact = MemoryFact(
                        type: .giftIdea, value: title, person: person,
                        confidence: extraction.confidence(for: "interests"), status: .suggested,
                        sourceCaptureUUID: capture.uuid, sourceInteractionUUID: interaction.uuid
                    )
                    context.insert(fact)
                    existingFacts.append(fact)
                    insertedGiftKeys.insert(key)
                    continue
                }
                let gift = GiftIdea(title: title, person: person, notes: "From capture on \(capture.capturedAt.shortFormat)")
                gift.sourceCaptureUUID = capture.uuid
                context.insert(gift)
                insertedGiftKeys.insert(key)
            }
        }
    }

    // MARK: Important dates

    @MainActor
    private func applyImportantDates(from extraction: AIExtraction, capture: CapturedMemory, interaction: Interaction, people: [Person], context: ModelContext) {
        let confidence = extraction.confidence(for: "importantDates")
        var existingFacts = Self.facts(for: capture, context: context)

        for extracted in extraction.importantDates {
            let attributed = matchAttributed(extracted.personNames, among: people)
            let isBirthday = extracted.title == "Birthday"
            let display = extracted.display.isEmpty ? extracted.title : extracted.display

            // Imported conversations are evidence, not permission to add a
            // calendar item. They always land as provenance-linked facts
            // for review, even when the model supplied a concrete date.
            if capture.source == .instagram {
                guard !display.isEmpty else { continue }
                insertFact(type: .importantDate, value: display, people: attributed, confidence: confidence,
                           status: .suggested, capture: capture, interaction: interaction, existing: &existingFacts,
                           dateValue: extracted.date, context: context)
                continue
            }

            guard let dateValue = extracted.date else {
                // Incomplete/uncertain date: keep it as a suggestion, never
                // invent a year, month, or day.
                guard !display.isEmpty else { continue }
                insertFact(type: .importantDate, value: display, people: attributed, confidence: confidence,
                           status: .suggested, capture: capture, interaction: interaction, existing: &existingFacts,
                           context: context)
                continue
            }

            // Birthdays NEVER write directly to `Person.birthday` from
            // automation, regardless of confidence; always a fact the
            // user explicitly promotes later (see `MemoryFactPromotion`).
            // Ambiguous attribution (0 or 2+ people) or low confidence for
            // a non-birthday date also stays a suggestion rather than
            // guessing which single person it's really about.
            guard !isBirthday, confidence >= 0.6, attributed.count == 1, let person = attributed.first else {
                insertFact(type: .importantDate, value: display, people: attributed, confidence: confidence,
                           status: .suggested, capture: capture, interaction: interaction, existing: &existingFacts,
                           dateValue: dateValue, context: context)
                continue
            }

            let sameDay = person.importantDates.contains {
                $0.title.caseInsensitiveCompare(extracted.title) == .orderedSame
                    && Calendar.current.isDate($0.date, equalTo: dateValue, toGranularity: .day)
            }
            guard !sameDay else { continue }
            let record = ImportantDate(title: extracted.title, date: dateValue, person: person)
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
    /// ideas, and memory facts, found by their explicit `sourceCaptureUUID`
    /// stamp, never by guessing from titles or dates. Idempotent: calling
    /// this twice (or after the records are already gone) is a safe no-op.
    /// Never touches `Person.birthday` because automated processing never
    /// writes there directly in the first place (see `applyImportantDates`).
    @MainActor
    func undo(_ capture: CapturedMemory) {
        guard capture.status != .dismissed else { return }
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
    /// place; use `undo` first for a full reversal) plus its image files.
    @MainActor
    func delete(_ capture: CapturedMemory) {
        for url in capture.imageURLs() {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(capture)
        save()
    }

    // MARK: Lookups shared with the UI

    @MainActor
    static func interaction(for capture: CapturedMemory, context: ModelContext) -> Interaction? {
        let target: UUID? = capture.uuid
        let descriptor = FetchDescriptor<Interaction>(predicate: #Predicate { $0.sourceCaptureUUID == target })
        return (try? context.fetch(descriptor))?.first
    }

    @MainActor
    static func facts(for capture: CapturedMemory, context: ModelContext) -> [MemoryFact] {
        let target: UUID? = capture.uuid
        let descriptor = FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.sourceCaptureUUID == target })
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func reminders(for capture: CapturedMemory, context: ModelContext) -> [Reminder] {
        let target: UUID? = capture.uuid
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.sourceCaptureUUID == target })
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Share-extension ingestion

    /// Imports every payload the Share Extension queued into durable
    /// `CapturedMemory` records. Each entry is removed from the App Group
    /// queue only *after* its SwiftData record has been persisted
    /// (`persistNewCapture`), so a crash mid-import re-imports (idempotently,
    /// by shared UUID) instead of losing anything.
    @MainActor
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
            if persistNewCapture(capture) == nil {
                SharedImportInbox.remove(entry.id, deletingImages: true)
            }
            // On failure, leave the entry queued; it will be retried next
            // activation. `persistNewCapture` already rolled the object
            // back, so nothing is left half-inserted.
        }
    }

    /// Re-queues captures a crash or kill left stuck mid-`processing`.
    @MainActor
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

    @MainActor
    private func aliasMap(for people: [Person]) -> [String: String] {
        var map: [String: String] = [:]
        for person in people where !person.nickname.isEmpty && person.nickname != person.name {
            map[person.nickname] = person.name
        }
        return map
    }

    @MainActor
    private func existingFactDigest(for people: [Person]) -> [String] {
        var digest: [String] = []
        for person in people {
            digest.append(contentsOf: person.combinedInterests.map { "\(person.firstName) likes \($0)" })
            digest.append(contentsOf: person.visibleFacts.prefix(10).map { "\(person.firstName): \($0.value)" })
        }
        return digest
    }

    @MainActor
    private func save(_ suppliedContext: ModelContext? = nil) {
        try? (suppliedContext ?? context).save()
    }
}
