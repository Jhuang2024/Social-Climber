#if DEBUG
import Foundation
import SwiftData

/// Explicit, on-device validation of the capture pipeline's correctness
/// invariants: undo completeness, idempotent reprocessing, no invented
/// reminder dates, no automatic birthday mutation, and multi-person
/// attribution, run against the REAL `CaptureProcessor` and the real
/// store. DEBUG-only, manually triggered from Diagnostics (never runs on
/// its own): it creates its own clearly-marked throwaway people/captures
/// and fully removes everything it created afterward, so it never pollutes
/// real user data.
@MainActor
enum CaptureIntegrityValidator {
    struct CheckResult: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run(context: ModelContext) async -> [CheckResult] {
        var results: [CheckResult] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            results.append(CheckResult(name: name, passed: passed, detail: detail))
        }

        let tag = UUID().uuidString.prefix(6)
        let person = Person(name: "ZZ-IntegrityTest-\(tag)", category: .friend, closeness: 3, priority: 3)
        let personB = Person(name: "ZZ-IntegrityTest-\(tag)-B", category: .friend, closeness: 3, priority: 3)
        context.insert(person)
        context.insert(personB)

        var createdCaptureUUIDs: [UUID] = []
        defer { cleanUp(people: [person, personB], captureUUIDs: createdCaptureUUIDs, context: context) }

        // MARK: 1. Basic pipeline + no invented reminder date + no direct birthday write

        let capture = CapturedMemory(
            rawText: "Coffee with \(person.name). Remind me tomorrow to send the deck. Her birthday is March 3.",
            source: .text,
            capturedAt: .now,
            trustedPersonIDs: [person.uuid],
            trustedPersonNames: [person.name]
        )
        context.insert(capture)
        try? context.save()
        createdCaptureUUIDs.append(capture.uuid)

        await CaptureProcessor.shared.process(capture)
        check("Capture reaches .processed", capture.status == .processed, "status=\(capture.status.rawValue) error=\(capture.errorMessage)")

        let interaction1 = CaptureProcessor.interaction(for: capture, context: context)
        check("Exactly one interaction created", interaction1 != nil)

        let reminders1 = CaptureProcessor.reminders(for: capture, context: context)
        check("Explicit reminder with a resolvable date is scheduled", reminders1.count == 1, "count=\(reminders1.count)")

        check("Person.birthday is NEVER written directly by automation", person.birthday == nil)
        let facts1 = CaptureProcessor.facts(for: capture, context: context)
        check("Birthday instead becomes a suggested MemoryFact", facts1.contains { $0.type == .importantDate && $0.status == .suggested })

        let closenessBeforeManualEdit = person.closeness

        // MARK: 2. Idempotent reprocessing (retry / relaunch race)

        capture.status = .queued
        await CaptureProcessor.shared.process(capture)
        let interaction2 = CaptureProcessor.interaction(for: capture, context: context)
        check("Reprocessing keeps the same interaction (no duplicate)", interaction1?.persistentModelID == interaction2?.persistentModelID)

        let allInteractionsForCapture = ((try? context.fetch(FetchDescriptor<Interaction>())) ?? [])
            .filter { $0.sourceCaptureUUID == capture.uuid }
        check("Exactly one interaction exists after reprocessing", allInteractionsForCapture.count == 1, "count=\(allInteractionsForCapture.count)")
        check("Reprocessing does not duplicate reminders", CaptureProcessor.reminders(for: capture, context: context).count == reminders1.count)
        check("Reprocessing does not duplicate facts", CaptureProcessor.facts(for: capture, context: context).count == facts1.count)

        // MARK: 3. Undo after a later manual edit must reverse the CURRENT
        //          state, not clobber it, and must not touch unrelated data.

        if let interaction = interaction1 {
            InteractionSaver.updateQuality(of: interaction, to: Sentiment.great.quality)
        }
        let closenessAfterManualEdit = person.closeness

        CaptureProcessor.shared.undo(capture)
        check("Undo removes the interaction", CaptureProcessor.interaction(for: capture, context: context) == nil)
        check("Undo removes reminders", CaptureProcessor.reminders(for: capture, context: context).isEmpty)
        check("Undo removes facts", CaptureProcessor.facts(for: capture, context: context).isEmpty)
        let datesAfterUndo = ((try? context.fetch(FetchDescriptor<ImportantDate>())) ?? []).filter { $0.sourceCaptureUUID == capture.uuid }
        check("Undo removes important dates", datesAfterUndo.isEmpty)
        let giftsAfterUndo = ((try? context.fetch(FetchDescriptor<GiftIdea>())) ?? []).filter { $0.sourceCaptureUUID == capture.uuid }
        check("Undo removes gift ideas", giftsAfterUndo.isEmpty)
        check(
            "Undo reverses exactly the closeness delta recorded at undo time (post-manual-edit), not a stale value",
            person.closeness == closenessBeforeManualEdit,
            "before=\(closenessBeforeManualEdit) afterEdit=\(closenessAfterManualEdit) afterUndo=\(person.closeness)"
        )
        check("Last-contacted restored to nil (no interactions remain)", person.lastContactedAt == nil)

        // MARK: 4. Repeated undo is a safe no-op

        CaptureProcessor.shared.undo(capture)
        check("Repeated undo does not throw or resurrect anything", capture.status == .dismissed)

        // MARK: 5. Unscheduled reminder suggestion (explicit, no resolvable date)

        let suggestionCapture = CapturedMemory(
            rawText: "Remind me to send \(person.name) the deck.",
            source: .text,
            capturedAt: .now,
            trustedPersonIDs: [person.uuid],
            trustedPersonNames: [person.name]
        )
        context.insert(suggestionCapture)
        try? context.save()
        createdCaptureUUIDs.append(suggestionCapture.uuid)
        await CaptureProcessor.shared.process(suggestionCapture)

        let suggestionReminders = CaptureProcessor.reminders(for: suggestionCapture, context: context)
        check("No date-invented reminder is scheduled", suggestionReminders.isEmpty, "count=\(suggestionReminders.count)")
        let suggestionFacts = CaptureProcessor.facts(for: suggestionCapture, context: context)
        check(
            "Explicit-but-unresolvable reminder becomes an unscheduled suggestion",
            suggestionFacts.contains { $0.type == .reminderSuggestion && $0.dateValue == nil }
        )

        // MARK: 6. Implied follow-up never becomes a reminder

        let impliedCapture = CapturedMemory(
            rawText: "I should probably message \(person.name) again sometime.",
            source: .text,
            capturedAt: .now,
            trustedPersonIDs: [person.uuid],
            trustedPersonNames: [person.name]
        )
        context.insert(impliedCapture)
        try? context.save()
        createdCaptureUUIDs.append(impliedCapture.uuid)
        await CaptureProcessor.shared.process(impliedCapture)
        check("Implied follow-up creates no scheduled reminder", CaptureProcessor.reminders(for: impliedCapture, context: context).isEmpty)

        // MARK: 7. Multi-person attribution: a fact about one named person
        //          in a multi-person capture must not attach to the other.

        let attributionCapture = CapturedMemory(
            rawText: "Met \(person.name) and \(personB.name). \(personB.name) is joining the robotics club.",
            source: .text,
            capturedAt: .now,
            trustedPersonIDs: [person.uuid, personB.uuid],
            trustedPersonNames: [person.name, personB.name]
        )
        context.insert(attributionCapture)
        try? context.save()
        createdCaptureUUIDs.append(attributionCapture.uuid)
        await CaptureProcessor.shared.process(attributionCapture)

        let attributionFacts = CaptureProcessor.facts(for: attributionCapture, context: context)
        let roboticsFacts = attributionFacts.filter { $0.value.localizedCaseInsensitiveContains("robotics") }
        check("A fact about a specific named person is found", !roboticsFacts.isEmpty)
        check(
            "That fact attaches ONLY to the person actually named, never to whoever resolved first",
            roboticsFacts.allSatisfy { $0.person?.persistentModelID == personB.persistentModelID },
            roboticsFacts.map { "\($0.value) → \($0.person?.name ?? "unattributed")" }.joined(separator: "; ")
        )

        return results
    }

    private static func cleanUp(people: [Person], captureUUIDs: [UUID], context: ModelContext) {
        for uuid in captureUUIDs {
            if let interactions = try? context.fetch(FetchDescriptor<Interaction>(predicate: #Predicate { $0.sourceCaptureUUID == uuid })) {
                for i in interactions { context.delete(i) }
            }
            if let reminders = try? context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.sourceCaptureUUID == uuid })) {
                for r in reminders { context.delete(r) }
            }
            if let dates = try? context.fetch(FetchDescriptor<ImportantDate>(predicate: #Predicate { $0.sourceCaptureUUID == uuid })) {
                for d in dates { context.delete(d) }
            }
            if let gifts = try? context.fetch(FetchDescriptor<GiftIdea>(predicate: #Predicate { $0.sourceCaptureUUID == uuid })) {
                for g in gifts { context.delete(g) }
            }
            if let facts = try? context.fetch(FetchDescriptor<MemoryFact>(predicate: #Predicate { $0.sourceCaptureUUID == uuid })) {
                for f in facts { context.delete(f) }
            }
            if let captures = try? context.fetch(FetchDescriptor<CapturedMemory>(predicate: #Predicate { $0.uuid == uuid })) {
                for c in captures { context.delete(c) }
            }
        }
        for person in people {
            NotificationService.shared.cancelBirthday(for: person)
            context.delete(person)
        }
        try? context.save()
    }
}
#endif
