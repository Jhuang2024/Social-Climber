import Foundation

/// The language a live recording is spoken in. Chosen by the user before
/// recording, because on-device `SFSpeechRecognizer` locks to a single locale
/// per request and cannot reliably auto-detect the language mid-stream. A
/// non-English recording is transcribed in its own language (so the recogniser
/// is accurate), then translated to English before parsing, with the original
/// always preserved.
enum RecordingLanguage: String, CaseIterable, Identifiable, Sendable {
    case english
    case mandarin

    var id: String { rawValue }

    /// Short, user-facing label for the picker.
    var label: String {
        switch self {
        case .english: "English"
        case .mandarin: "中文"
        }
    }

    /// Accessible/spelled-out name for VoiceOver and longer contexts.
    var longLabel: String {
        switch self {
        case .english: "English"
        case .mandarin: "Mandarin (中文)"
        }
    }

    /// The locale handed to the speech recogniser for this language.
    var recognizerLocale: Locale {
        switch self {
        case .english: Locale(identifier: "en-US")
        case .mandarin: Locale(identifier: "zh-CN")
        }
    }

    /// True when transcripts in this language must be translated to English
    /// before the AI parses them.
    var needsTranslationToEnglish: Bool { self != .english }

    /// The source `Locale.Language` used to configure a translation session,
    /// or `nil` when no translation is needed.
    var translationSourceLanguage: Locale.Language? {
        switch self {
        case .english: nil
        case .mandarin: Locale.Language(identifier: "zh-Hans")
        }
    }

    /// Derives the recording language from a persisted BCP-47 identifier (e.g.
    /// a `VoiceNote.detectedLanguage`), defaulting to English.
    static func from(languageCode: String?) -> RecordingLanguage {
        guard let code = languageCode?.lowercased() else { return .english }
        if code.hasPrefix("zh") { return .mandarin }
        return .english
    }
}

/// Whether Apple's on-device translation is usable on this OS. The programmatic
/// `TranslationSession` / `.translationTask` API this app relies on is iOS 18+.
/// On older systems a Mandarin recording is still transcribed in Mandarin; it
/// just isn't auto-translated, and the UI says so instead of silently failing.
enum TranslationSupport {
    static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }
}
