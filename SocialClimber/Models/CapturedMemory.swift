import Foundation
import SwiftData
import SwiftUI

/// How a capture entered the app.
enum CaptureSource: String, Codable, CaseIterable, Identifiable {
    case text
    case voice
    case share
    case photo
    case intent
    case contactFollowUp
    case event

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Typed"
        case .voice: "Voice debrief"
        case .share: "Shared"
        case .photo: "Screenshot"
        case .intent: "Siri / Shortcut"
        case .contactFollowUp: "Contact follow-up"
        case .event: "Event"
        }
    }

    var icon: String {
        switch self {
        case .text: "text.cursor"
        case .voice: "waveform"
        case .share: "square.and.arrow.down"
        case .photo: "photo"
        case .intent: "sparkles"
        case .contactFollowUp: "phone.arrow.up.right"
        case .event: "party.popper"
        }
    }
}

/// Lifecycle of a capture as it moves through the processing pipeline.
enum CaptureStatus: String, Codable, CaseIterable, Identifiable {
    case queued
    case processing
    case processed
    case needsContext
    case failed
    case dismissed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .processing: "Organizing…"
        case .processed: "Remembered"
        case .needsContext: "Who was this with?"
        case .failed: "Couldn't process"
        case .dismissed: "Undone"
        }
    }

    var icon: String {
        switch self {
        case .queued: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .processed: "checkmark.circle.fill"
        case .needsContext: "person.fill.questionmark"
        case .failed: "exclamationmark.triangle.fill"
        case .dismissed: "arrow.uturn.backward.circle"
        }
    }

    var color: Color {
        switch self {
        case .queued, .processing: .secondary
        case .processed: .green
        case .needsContext: .orange
        case .failed: .red
        case .dismissed: .gray
        }
    }
}

/// The durable record of one raw, unstructured memory the user handed to
/// Social Climber ("Coffee with Jimmy, remind me Friday…"). Persisted
/// *before* any AI/OCR work so the capture survives termination, network
/// failure, or a crash; `CaptureProcessor` later organizes it into an
/// interaction, reminders, dates, gifts, and `MemoryFact`s. Everything the
/// processor creates is stamped with this capture's `uuid`
/// (`sourceCaptureUUID` on the created records), which is what makes a full,
/// exact undo possible without guessing by title or date.
@Model
final class CapturedMemory {
    /// Stable identity, used to stamp every record this capture produces.
    var uuid: UUID = UUID()
    /// The raw text as typed/pasted/shared. Preserved verbatim, always.
    var rawText: String = ""
    /// On-device transcript when the capture came from a voice debrief.
    var transcript: String = ""
    /// Text recognized on-device from any attached screenshots.
    var ocrText: String = ""
    /// File names inside `CapturedMemory.imagesDirectory`.
    var imagePaths: [String] = []
    var sourceRaw: String = CaptureSource.text.rawValue
    var capturedAt: Date = Date()

    // MARK: Trusted context supplied by the entry point
    /// Stable IDs of people supplied as trusted context (opened from a
    /// profile, an event, an intent, or assigned later from Needs Context).
    /// Resolved with confidence 1.0. Authoritative: `trustedPersonNames` is
    /// only a cached display copy, so renaming a person after capture but
    /// before processing can never break attribution, and a deleted person
    /// is simply dropped rather than silently misattributed.
    var trustedPersonIDs: [UUID] = []
    /// Cached display names for `trustedPersonIDs`, same order. Never
    /// authoritative; used only for UI/AI-prompt display when a live
    /// `Person` lookup isn't convenient.
    var trustedPersonNames: [String] = []
    var eventName: String = ""
    var eventDate: Date?
    var eventLocation: String = ""
    /// Optional interaction-type hint from the entry point (e.g. a
    /// "Did you reach Jimmy?" call follow-up, or a Shortcut parameter).
    var typeHintRaw: String = ""

    // MARK: Processing state
    var statusRaw: String = CaptureStatus.queued.rawValue
    var attempts: Int = 0
    var errorMessage: String = ""
    /// Stable IDs of the people the processor confidently attached.
    /// Authoritative; `resolvedPersonNames` is a cached display copy.
    var resolvedPersonIDs: [UUID] = []
    var resolvedPersonNames: [String] = []
    /// Stable IDs offered as one-tap candidate chips when the person is
    /// ambiguous. Authoritative; `candidatePersonNames` is a cached copy.
    var candidatePersonIDs: [UUID] = []
    var candidatePersonNames: [String] = []
    var inferenceConfidence: Double = 0
    var needsClarification: Bool = false
    /// True once the AI provider was tried and the local fallback was used.
    var usedLocalFallback: Bool = false

    // MARK: Result presentation
    /// Short feed headline, e.g. "Coffee with Jimmy".
    var title: String = ""
    /// One-line feed detail, e.g. "Stripe application · reminder created for Friday".
    var detail: String = ""

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        rawText: String,
        source: CaptureSource,
        transcript: String = "",
        imagePaths: [String] = [],
        capturedAt: Date = .now,
        trustedPersonIDs: [UUID] = [],
        trustedPersonNames: [String] = [],
        eventName: String = "",
        eventDate: Date? = nil,
        eventLocation: String = "",
        typeHint: InteractionType? = nil
    ) {
        self.uuid = UUID()
        self.rawText = rawText
        self.sourceRaw = source.rawValue
        self.transcript = transcript
        self.imagePaths = imagePaths
        self.capturedAt = capturedAt
        self.trustedPersonIDs = trustedPersonIDs
        self.trustedPersonNames = trustedPersonNames
        self.eventName = eventName
        self.eventDate = eventDate
        self.eventLocation = eventLocation
        self.typeHintRaw = typeHint?.rawValue ?? ""
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// Convenience initializer taking live `Person` objects: fills both the
    /// authoritative ID arrays and the cached display names in one call.
    convenience init(
        rawText: String,
        source: CaptureSource,
        transcript: String = "",
        imagePaths: [String] = [],
        capturedAt: Date = .now,
        trustedPeople: [Person],
        eventName: String = "",
        eventDate: Date? = nil,
        eventLocation: String = "",
        typeHint: InteractionType? = nil
    ) {
        self.init(
            rawText: rawText,
            source: source,
            transcript: transcript,
            imagePaths: imagePaths,
            capturedAt: capturedAt,
            trustedPersonIDs: trustedPeople.map(\.uuid),
            trustedPersonNames: trustedPeople.map(\.displayName),
            eventName: eventName,
            eventDate: eventDate,
            eventLocation: eventLocation,
            typeHint: typeHint
        )
    }

    var source: CaptureSource {
        get { CaptureSource(rawValue: sourceRaw) ?? .text }
        set { sourceRaw = newValue.rawValue }
    }

    var status: CaptureStatus {
        get { CaptureStatus(rawValue: statusRaw) ?? .queued }
        set {
            statusRaw = newValue.rawValue
            needsClarification = newValue == .needsContext
            updatedAt = .now
        }
    }

    var typeHint: InteractionType? {
        typeHintRaw.isEmpty ? nil : InteractionType(rawValue: typeHintRaw)
    }

    /// Everything textual this capture carries, in priority order, for
    /// parsing and extraction.
    var effectiveText: String {
        [rawText, transcript, ocrText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// A short preview of the raw content for feed rows.
    var preview: String {
        let text = effectiveText.replacingOccurrences(of: "\n", with: " ")
        guard text.count > 90 else { return text }
        return String(text.prefix(90)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Where attached capture images live (main app sandbox, so they
    /// survive the App Group share queue being drained).
    static var imagesDirectory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("CaptureImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func imageURLs() -> [URL] {
        imagePaths.map { Self.imagesDirectory.appendingPathComponent($0) }
    }

    /// Resolves a list of stable person IDs against a live `people` list,
    /// preserving `ids`' order and silently dropping any ID that no longer
    /// resolves (the person was deleted), the graceful-degradation rule
    /// used everywhere a capture's stored IDs need to become real `Person`
    /// objects again.
    static func resolvePeople(ids: [UUID], in people: [Person]) -> [Person] {
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.uuid, $0) })
        return ids.compactMap { byID[$0] }
    }
}
