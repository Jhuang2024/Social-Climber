import AppIntents
import Foundation
import SwiftData

// MARK: - Person entity

/// A person exposed to Siri/Shortcuts, identified by their display name
/// (the app's stable, user-facing identity for a contact).
struct PersonEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static var defaultQuery = PersonEntityQuery()

    /// The person's full name.
    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

struct PersonEntityQuery: EntityStringQuery {
    @MainActor
    private func allPeople() -> [Person] {
        (try? AppServices.container.mainContext.fetch(FetchDescriptor<Person>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PersonEntity] {
        let people = allPeople()
        return identifiers.compactMap { id in
            people.first { $0.name.caseInsensitiveCompare(id) == .orderedSame }.map { PersonEntity(id: $0.name) }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PersonEntity] {
        allPeople()
            .filter { $0.name.localizedCaseInsensitiveContains(string) || $0.nickname.localizedCaseInsensitiveContains(string) }
            .prefix(10)
            .map { PersonEntity(id: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PersonEntity] {
        allPeople()
            .filter { !$0.isArchived }
            .sorted { ($0.lastContactedAt ?? .distantPast) > ($1.lastContactedAt ?? .distantPast) }
            .prefix(8)
            .map { PersonEntity(id: $0.name) }
    }
}

// MARK: - Interaction type enum

enum CaptureTypeAppEnum: String, AppEnum {
    case inPerson
    case call
    case message
    case videoCall
    case email
    case event
    case other

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Interaction Type"
    static var caseDisplayRepresentations: [CaptureTypeAppEnum: DisplayRepresentation] = [
        .inPerson: "In Person",
        .call: "Call",
        .message: "Text",
        .videoCall: "Video Call",
        .email: "Email",
        .event: "Event",
        .other: "Other",
    ]

    var interactionType: InteractionType {
        InteractionType(rawValue: rawValue) ?? .other
    }
}

// MARK: - Open Quick Capture

struct OpenQuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Quick Capture"
    static var description = IntentDescription("Opens Social Climber ready to remember something.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickCaptureRouter.shared.open()
        return .result()
    }
}

// MARK: - Remember interaction

struct RememberInteractionIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Remember Something"
    static var description = IntentDescription("Saves a natural-language memory — Social Climber organizes the person, date, and follow-ups automatically.")
    static var openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What do you want to remember?")
    var note: String?

    @Parameter(title: "Person")
    var person: PersonEntity?

    @Parameter(title: "Type")
    var type: CaptureTypeAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Remember \(\.$note)") {
            \.$person
            \.$type
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // No note supplied: continue in the app with Quick Capture open.
            let trusted = person.map { [$0.id] } ?? []
            let hint = type?.interactionType
            throw needsToContinueInForegroundError("Open Quick Capture to finish.") {
                QuickCaptureRouter.shared.open(QuickCaptureRequest(trustedPersonNames: trusted, typeHint: hint))
            }
        }

        let context = AppServices.container.mainContext
        let capture = CapturedMemory(
            rawText: trimmed,
            source: .intent,
            capturedAt: .now,
            trustedPersonNames: person.map { [$0.id] } ?? [],
            typeHint: type?.interactionType
        )
        context.insert(capture)
        try? context.save()
        Task { await CaptureProcessor.shared.processQueued() }
        return .result(dialog: "Remembered.")
    }
}

// MARK: - Mark person contacted

struct MarkPersonContactedIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Person Contacted"
    static var description = IntentDescription("Logs a quick neutral contact with someone, updating their timeline and last-contacted date.")
    static var openAppWhenRun = false

    @Parameter(title: "Person", requestValueDialog: "Who did you contact?")
    var person: PersonEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$person) as contacted")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppServices.container.mainContext
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        guard let match = people.first(where: { $0.name.caseInsensitiveCompare(person.id) == .orderedSame }) else {
            return .result(dialog: "Couldn't find \(person.id) in Social Climber.")
        }
        let interaction = Interaction(
            type: .message,
            date: .now,
            quality: 3,
            messageSummary: "Marked as contacted"
        )
        InteractionSaver.finalize(interaction, people: [match], context: context)
        try? context.save()
        return .result(dialog: "Marked \(match.firstName) as contacted.")
    }
}

// MARK: - App Shortcuts

struct SocialClimberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RememberInteractionIntent(),
            phrases: [
                "Remember something in \(.applicationName)",
                "Tell \(.applicationName) to remember",
                "Log a memory in \(.applicationName)",
            ],
            shortTitle: "Remember",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenQuickCaptureIntent(),
            phrases: [
                "Open capture in \(.applicationName)",
                "New capture in \(.applicationName)",
            ],
            shortTitle: "Quick Capture",
            systemImageName: "text.badge.plus"
        )
        AppShortcut(
            intent: MarkPersonContactedIntent(),
            phrases: [
                "Mark someone contacted in \(.applicationName)",
                "I reached out in \(.applicationName)",
            ],
            shortTitle: "Contacted",
            systemImageName: "checkmark.circle"
        )
    }
}
