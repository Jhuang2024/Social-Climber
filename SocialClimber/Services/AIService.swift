import Foundation
import UIKit

// MARK: - Extraction output

struct ExtractedDate: Codable, Hashable, Sendable {
    var title: String
    var date: Date?
    var display: String
    /// Names of the people this date is about, as written/matched in the
    /// source text. Empty means unattributed: never guessed, never
    /// defaulted to "whoever was resolved first" for this capture.
    var personNames: [String] = []

    enum CodingKeys: String, CodingKey { case title, date, display, personNames }

    init(title: String, date: Date? = nil, display: String, personNames: [String] = []) {
        self.title = title
        self.date = date
        self.display = display
        self.personNames = personNames
    }

    /// Defensive decode so a provider response (or a cached payload) from
    /// before `personNames` existed still decodes in full.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decodeIfPresent(Date.self, forKey: .date)
        display = try c.decode(String.self, forKey: .display)
        personNames = (try? c.decodeIfPresent([String].self, forKey: .personNames)) ?? []
    }
}

struct ExtractedReminder: Codable, Hashable, Sendable {
    var title: String
    var dueDate: Date?
    /// Names of the people this reminder is about, as written/matched in
    /// the source text. Empty means unattributed.
    var personNames: [String] = []

    enum CodingKeys: String, CodingKey { case title, dueDate, personNames }

    init(title: String, dueDate: Date? = nil, personNames: [String] = []) {
        self.title = title
        self.dueDate = dueDate
        self.personNames = personNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        personNames = (try? c.decodeIfPresent([String].self, forKey: .personNames)) ?? []
    }
}

/// One extracted, attributable fact: a value (an interest, a school/work
/// note, a gift idea, an implied follow-up…) plus the specific people it's
/// about, matched by name against the text it came from. This is what
/// replaces "attach every fact to whichever person happens to be first";
/// `personNames` is empty when the text didn't clearly name anyone, one
/// name when it named exactly one person, and more than one when the text
/// genuinely names several people sharing the same fact (e.g. "Daniel and
/// Priya are both training for a marathon"). `factType` matches
/// `MemoryFactType`'s raw value.
struct ExtractedFact: Codable, Hashable, Sendable {
    var factType: String
    var value: String
    var personNames: [String] = []

    enum CodingKeys: String, CodingKey { case factType, value, personNames }

    init(factType: String, value: String, personNames: [String] = []) {
        self.factType = factType
        self.value = value
        self.personNames = personNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        factType = try c.decode(String.self, forKey: .factType)
        value = try c.decode(String.self, forKey: .value)
        personNames = (try? c.decodeIfPresent([String].self, forKey: .personNames)) ?? []
    }
}

struct AIExtraction: Codable, Sendable {
    var summary: String = ""
    var peopleMentioned: [String] = []
    var topics: [String] = []
    var interests: [String] = []
    var giftIdeas: [String] = []
    var importantDates: [ExtractedDate] = []
    /// Explicit follow-up instructions only ("remind me Friday…"). Merely
    /// implied follow-ups belong in `impliedFollowUps`.
    var reminders: [ExtractedReminder] = []
    var followUpQuestions: [String] = []
    var personalityNotes: [String] = []
    var confidence: Double = 0.5

    // MARK: Automatic-organization fields
    /// Inferred interaction kind, matching `InteractionType` raw values
    /// ("inPerson", "call", "message", "videoCall", "event", "email").
    /// `nil` when the input doesn't say.
    var inferredInteractionType: String?
    /// When the interaction happened, resolved against the capture date.
    /// `nil` unless the input clearly states it.
    var inferredDate: Date?
    /// Sentiment ONLY when the user explicitly described how it went
    /// ("bad", "neutral", "good", "great"); nil otherwise.
    var explicitSentiment: String?
    var dislikes: [String] = []
    /// School/work statements about the other person ("applying to Stripe").
    var schoolOrWorkFacts: [String] = []
    /// Location statements about the other person ("moving to New York").
    var locationFacts: [String] = []
    /// Family/relationship statements ("her sister just had a baby").
    var familyFacts: [String] = []
    /// Follow-ups that were implied but never explicitly requested; stored
    /// as suggestions, never scheduled automatically.
    var impliedFollowUps: [String] = []
    /// 0–1 confidence per category ("interests", "reminders",
    /// "importantDates", "people", "date", "type", "sentiment", …). Missing
    /// keys fall back to the overall `confidence`.
    var fieldConfidence: [String: Double] = [:]
    /// Per-item, per-person-attributed facts: the mechanism the capture
    /// pipeline uses to create `MemoryFact`s correctly attributed to
    /// whichever specific person the source text actually names, instead of
    /// flattening every fact onto "whoever was resolved first". Populated
    /// in parallel with (not instead of) the legacy flat-string arrays
    /// above, which the manual/advanced editing flows still use unchanged.
    var attributedFacts: [ExtractedFact] = []

    enum CodingKeys: String, CodingKey {
        case summary
        case peopleMentioned
        case topics
        case interests
        case giftIdeas
        case importantDates
        case reminders
        case followUpQuestions
        case personalityNotes
        case confidence
        case confidenceScore
        case inferredInteractionType
        case inferredDate
        case explicitSentiment
        case dislikes
        case schoolOrWorkFacts
        case locationFacts
        case familyFacts
        case impliedFollowUps
        case fieldConfidence
        case attributedFacts
    }

    init(
        summary: String = "",
        peopleMentioned: [String] = [],
        topics: [String] = [],
        interests: [String] = [],
        giftIdeas: [String] = [],
        importantDates: [ExtractedDate] = [],
        reminders: [ExtractedReminder] = [],
        followUpQuestions: [String] = [],
        personalityNotes: [String] = [],
        confidence: Double = 0.5
    ) {
        self.summary = summary
        self.peopleMentioned = peopleMentioned
        self.topics = topics
        self.interests = interests
        self.giftIdeas = giftIdeas
        self.importantDates = importantDates
        self.reminders = reminders
        self.followUpQuestions = followUpQuestions
        self.personalityNotes = personalityNotes
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        peopleMentioned = try container.decodeIfPresent([String].self, forKey: .peopleMentioned) ?? []
        topics = try container.decodeIfPresent([String].self, forKey: .topics) ?? []
        interests = try container.decodeIfPresent([String].self, forKey: .interests) ?? []
        giftIdeas = try container.decodeIfPresent([String].self, forKey: .giftIdeas) ?? []
        importantDates = try container.decodeIfPresent([ExtractedDate].self, forKey: .importantDates) ?? []
        reminders = try container.decodeIfPresent([ExtractedReminder].self, forKey: .reminders) ?? []
        followUpQuestions = try container.decodeIfPresent([String].self, forKey: .followUpQuestions) ?? []
        personalityNotes = try container.decodeIfPresent([String].self, forKey: .personalityNotes) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidenceScore)
            ?? container.decodeIfPresent(Double.self, forKey: .confidence)
            ?? 0.5
        // Every newer field decodes defensively so responses (or cached
        // payloads) from before these fields existed still decode in full.
        inferredInteractionType = (try? container.decodeIfPresent(String.self, forKey: .inferredInteractionType)) ?? nil
        inferredDate = (try? container.decodeIfPresent(Date.self, forKey: .inferredDate)) ?? nil
        explicitSentiment = (try? container.decodeIfPresent(String.self, forKey: .explicitSentiment)) ?? nil
        dislikes = (try? container.decodeIfPresent([String].self, forKey: .dislikes)) ?? []
        schoolOrWorkFacts = (try? container.decodeIfPresent([String].self, forKey: .schoolOrWorkFacts)) ?? []
        locationFacts = (try? container.decodeIfPresent([String].self, forKey: .locationFacts)) ?? []
        familyFacts = (try? container.decodeIfPresent([String].self, forKey: .familyFacts)) ?? []
        impliedFollowUps = (try? container.decodeIfPresent([String].self, forKey: .impliedFollowUps)) ?? []
        fieldConfidence = (try? container.decodeIfPresent([String: Double].self, forKey: .fieldConfidence)) ?? [:]
        attributedFacts = (try? container.decodeIfPresent([ExtractedFact].self, forKey: .attributedFacts)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(peopleMentioned, forKey: .peopleMentioned)
        try container.encode(topics, forKey: .topics)
        try container.encode(interests, forKey: .interests)
        try container.encode(giftIdeas, forKey: .giftIdeas)
        try container.encode(importantDates, forKey: .importantDates)
        try container.encode(reminders, forKey: .reminders)
        try container.encode(followUpQuestions, forKey: .followUpQuestions)
        try container.encode(personalityNotes, forKey: .personalityNotes)
        try container.encode(confidence, forKey: .confidenceScore)
        try container.encodeIfPresent(inferredInteractionType, forKey: .inferredInteractionType)
        try container.encodeIfPresent(inferredDate, forKey: .inferredDate)
        try container.encodeIfPresent(explicitSentiment, forKey: .explicitSentiment)
        try container.encode(dislikes, forKey: .dislikes)
        try container.encode(schoolOrWorkFacts, forKey: .schoolOrWorkFacts)
        try container.encode(locationFacts, forKey: .locationFacts)
        try container.encode(familyFacts, forKey: .familyFacts)
        try container.encode(impliedFollowUps, forKey: .impliedFollowUps)
        try container.encode(fieldConfidence, forKey: .fieldConfidence)
        try container.encode(attributedFacts, forKey: .attributedFacts)
    }

    /// Confidence for one category, falling back to the overall score.
    func confidence(for field: String) -> Double {
        fieldConfidence[field] ?? confidence
    }

    /// `attributedFacts` entries of one type ("interest", "dislike", …).
    func attributedFacts(ofType type: MemoryFactType) -> [ExtractedFact] {
        attributedFacts.filter { $0.factType == type.rawValue }
    }

    var isEmpty: Bool {
        topics.isEmpty && interests.isEmpty && giftIdeas.isEmpty
            && importantDates.isEmpty && reminders.isEmpty
            && followUpQuestions.isEmpty && personalityNotes.isEmpty
            && dislikes.isEmpty && schoolOrWorkFacts.isEmpty
            && locationFacts.isEmpty && familyFacts.isEmpty
            && impliedFollowUps.isEmpty && attributedFacts.isEmpty
    }
}

/// Everything the caller already trusts about a capture, handed to the
/// extraction provider so it can resolve relative dates correctly, avoid
/// re-extracting known facts, and tell the user apart from the contact.
struct AIExtractionContext: Sendable {
    /// When the note was captured; the anchor for "Friday", "next week"…
    var captureDate: Date = .now
    var timeZoneID: String = TimeZone.current.identifier
    /// People supplied as trusted context by the entry point.
    var trustedPersonNames: [String] = []
    /// Known nickname → full-name pairs for the trusted people.
    var aliases: [String: String] = [:]
    var eventName: String?
    /// Facts already on file for the trusted people, so the extraction can
    /// skip duplicating them.
    var existingFacts: [String] = []
}

// MARK: - Gift suggestions

/// A single AI-proposed gift idea, grounded in whatever the app already
/// knows about a person (interests, notes, tags, past interactions).
struct GiftSuggestion: Codable, Identifiable, Hashable {
    var title: String
    var reason: String = ""
    var priceRange: String = ""
    var occasion: String = ""

    var id: String { title }

    enum CodingKeys: String, CodingKey {
        case title, reason, priceRange, occasion
    }

    init(title: String, reason: String = "", priceRange: String = "", occasion: String = "") {
        self.title = title
        self.reason = reason
        self.priceRange = priceRange
        self.occasion = occasion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        priceRange = try container.decodeIfPresent(String.self, forKey: .priceRange) ?? ""
        occasion = try container.decodeIfPresent(String.self, forKey: .occasion) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(reason, forKey: .reason)
        try container.encode(priceRange, forKey: .priceRange)
        try container.encode(occasion, forKey: .occasion)
    }
}

// MARK: - Fit Checker

/// A single photo's outfit rated against the event it's headed to. Event-prep
/// assistance only: never written to a `Person` or `Interaction`, so it can
/// never touch closeness, cadence, or relationship scoring.
struct FitCheckResult: Codable, Hashable {
    var score: Int = 0
    var verdict: String = ""
    var strengths: [String] = []
    var weaknesses: [String] = []
    var improvements: [String] = []
    /// 0...1, how confident the model is given photo quality/angle/lighting.
    /// `nil` when the model didn't return one.
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case score, verdict, strengths, weaknesses, improvements, confidence
    }

    init(score: Int = 0, verdict: String = "", strengths: [String] = [], weaknesses: [String] = [], improvements: [String] = [], confidence: Double? = nil) {
        self.score = min(100, max(0, score))
        self.verdict = verdict
        self.strengths = strengths
        self.weaknesses = weaknesses
        self.improvements = improvements
        self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawScore = try container.decodeIfPresent(Int.self, forKey: .score) ?? 0
        score = min(100, max(0, rawScore))
        verdict = try container.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        strengths = try container.decodeIfPresent([String].self, forKey: .strengths) ?? []
        weaknesses = try container.decodeIfPresent([String].self, forKey: .weaknesses) ?? []
        improvements = try container.decodeIfPresent([String].self, forKey: .improvements) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

// MARK: - How to Respond

/// One candidate reply, always with a plain rationale; no bare text with no
/// explanation of when you'd actually send it.
struct ReplyOption: Codable, Hashable {
    var text: String = ""
    var why: String = ""

    enum CodingKeys: String, CodingKey {
        case text, why
    }

    init(text: String = "", why: String = "") {
        self.text = text
        self.why = why
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        why = try container.decodeIfPresent(String.self, forKey: .why) ?? ""
    }
}

/// Reply guidance for an incoming screenshot, grounded in a specific person's
/// existing profile. Purely an assist surface: analyzing a screenshot here
/// never creates an `Interaction` or touches closeness.
struct ReplyAdvice: Codable, Hashable {
    var recommendedReply: String = ""
    var alternates: [ReplyOption] = []
    var explanation: String = ""
    var tone: String = ""
    /// Set only when the incoming message reads as sensitive, risky, dry,
    /// hostile, or ambiguous; `nil` otherwise.
    var warning: String?

    enum CodingKeys: String, CodingKey {
        case recommendedReply, alternates, explanation, tone, warning
    }

    init(recommendedReply: String = "", alternates: [ReplyOption] = [], explanation: String = "", tone: String = "", warning: String? = nil) {
        self.recommendedReply = recommendedReply
        self.alternates = alternates
        self.explanation = explanation
        self.tone = tone
        self.warning = warning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recommendedReply = try container.decodeIfPresent(String.self, forKey: .recommendedReply) ?? ""
        alternates = try container.decodeIfPresent([ReplyOption].self, forKey: .alternates) ?? []
        explanation = try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        tone = try container.decodeIfPresent(String.self, forKey: .tone) ?? ""
        let rawWarning = try container.decodeIfPresent(String.self, forKey: .warning)
        warning = (rawWarning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : rawWarning
    }
}

// MARK: - Protocol

protocol AIService {
    func extract(from text: String, knownPeople: [String], context: AIExtractionContext) async throws -> AIExtraction
    func suggestGiftIdeas(personContext: String, existingGiftTitles: [String]) async throws -> [GiftSuggestion]
}

enum AIProvider: String, CaseIterable, Identifiable {
    case mock
    case bazaarLink

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mock: "Mock"
        case .bazaarLink: "AI (OpenRouter / BazaarLink)"
        }
    }

    var service: AIService {
        switch self {
        case .mock: MockAIService()
        case .bazaarLink: BazaarLinkAIService()
        }
    }

    /// The provider selected in Settings, defaulting to Mock. `.bazaarLink`'s
    /// raw value predates this app supporting two gateways, kept as-is so
    /// an existing stored preference doesn't silently reset, but now means
    /// "real AI, tried via whichever gateway key works" rather than
    /// literally BazaarLink only (see AIGatewayProvider / BazaarLinkAIService).
    static var currentCase: AIProvider {
        let raw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.mock.rawValue
        if raw == "openRouter" { return .bazaarLink }
        return AIProvider(rawValue: raw) ?? .mock
    }

    static var current: AIService { currentCase.service }
}

/// Which AI gateway served a request. OpenRouter is tried first (the app's
/// default provider); BazaarLink is the fallback, tried only if OpenRouter
/// has no key saved or its request fails.
enum AIGatewayProvider: CaseIterable {
    case openRouter
    case bazaarLink

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .bazaarLink: return "BazaarLink"
        }
    }

    var endpoint: URL {
        switch self {
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .bazaarLink: return URL(string: "https://bazaarlink.ai/api/v1/chat/completions")!
        }
    }

    /// Model ID used when Settings has no explicit override: each gateway's
    /// own "route to an available free model automatically" ID, so ordinary
    /// AI use costs nothing by default no matter which provider ends up
    /// serving the request.
    var defaultFreeModel: String {
        switch self {
        case .openRouter: return "openrouter/free"
        case .bazaarLink: return "auto:free"
        }
    }

    var apiKey: String? {
        switch self {
        case .openRouter: return try? KeychainService.openRouterAPIKey()
        case .bazaarLink: return try? KeychainService.bazaarLinkAPIKey()
        }
    }

    /// Optional app-attribution headers OpenRouter's dashboard/rankings use;
    /// harmless to send, meaningless to BazaarLink.
    var extraHeaders: [String: String] {
        switch self {
        case .openRouter: return ["HTTP-Referer": "https://localhost/social-climber", "X-Title": "Social Climber"]
        case .bazaarLink: return [:]
        }
    }

    func resolvedModel(override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultFreeModel : trimmed
    }
}

enum AIServiceError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case timeout
    case networkFailure
    case invalidResponse
    case emptyResponse
    case requestFailed(provider: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your OpenRouter or BazaarLink API key in Settings, or switch AI Provider to Mock."
        case .invalidAPIKey:
            "Your API key was rejected. Check it in Settings. Showing a local summary instead."
        case .rateLimited:
            "The AI provider is rate-limiting requests right now. Try again in a bit. Showing a local summary instead."
        case .timeout:
            "The AI request took too long and timed out. Showing a local summary instead."
        case .networkFailure:
            "Couldn't reach the AI provider. Check your connection. Showing a local summary instead."
        case .invalidResponse:
            "The AI provider returned a response Social Climber could not read."
        case .emptyResponse:
            "The AI provider returned an empty response."
        case .requestFailed(let provider, let status):
            "\(provider) request failed (HTTP \(status)). Check your API key and model in Settings."
        }
    }

    /// Maps a thrown error (ours, a decoding error, or a `URLError`) to a
    /// clean, user-facing `AIServiceError`, never a raw system error string.
    static func from(_ error: Error) -> AIServiceError {
        if let known = error as? AIServiceError { return known }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .networkFailure
            default:
                return .networkFailure
            }
        }
        if error is DecodingError { return .invalidResponse }
        return .invalidResponse
    }

    /// Logs a developer-facing diagnostic without ever including the API key
    /// or request/response bodies (which may contain the user's private notes).
    func logForDeveloper(context: String) {
        #if DEBUG
        print("[AIService] \(context) failed: \(self)")
        #endif
    }
}

/// A dedicated session with tight timeouts so a slow or hanging AI provider
/// can never leave the UI spinning indefinitely.
private let aiURLSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 25
    return URLSession(configuration: configuration)
}()

/// Races `operation` against a hard deadline so a hung request can never
/// block the caller past `seconds`, even if the underlying `URLSession`
/// timeout somehow doesn't fire (e.g. a stalled DNS resolution).
func withAITimeout<T: Sendable>(seconds: TimeInterval = 20, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AIServiceError.timeout
        }
        guard let result = try await group.next() else {
            throw AIServiceError.timeout
        }
        group.cancelAll()
        return result
    }
}

final class BazaarLinkAIService: AIService {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func extract(from text: String, knownPeople: [String], context: AIExtractionContext) async throws -> AIExtraction {
        let model = UserDefaults.standard.string(forKey: "bazaarLinkModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await Self.send(modelOverride: model, decoder: decoder) { resolvedModel in
            BazaarLinkRequest(
                model: resolvedModel,
                messages: [
                    .init(role: "system", content: Self.systemPrompt),
                    .init(role: "user", content: Self.userPrompt(text: text, knownPeople: knownPeople, context: context)),
                ],
                temperature: 0.2,
                responseFormat: .init(type: "json_object")
            )
        }
        return try Self.decodeExtraction(from: result.content, decoder: decoder)
    }

    /// Tries each configured AI gateway in order (OpenRouter first, then
    /// BazaarLink), skipping any with no saved key, until one answers
    /// successfully. `makeBody` builds the strongly-typed request body for a
    /// given provider's resolved model, since the model ID is embedded in
    /// the Encodable struct rather than a loose dictionary.
    private static func send<Body: Encodable>(
        modelOverride: String?,
        decoder: JSONDecoder,
        makeBody: (String) -> Body
    ) async throws -> (content: String, provider: AIGatewayProvider, model: String) {
        var lastError: Error = AIServiceError.missingAPIKey
        var attempted = false
        for provider in AIGatewayProvider.allCases {
            guard let apiKey = provider.apiKey else { continue }
            attempted = true
            let model = provider.resolvedModel(override: modelOverride)
            do {
                let content = try await sendOnce(makeBody(model), apiKey: apiKey, provider: provider, decoder: decoder)
                return (content, provider, model)
            } catch {
                lastError = error
                continue
            }
        }
        guard attempted else { throw AIServiceError.missingAPIKey }
        throw lastError
    }

    /// Runs one chat completion against a single gateway and returns the raw
    /// assistant message text.
    private static func sendOnce<Body: Encodable>(
        _ requestBody: Body,
        apiKey: String,
        provider: AIGatewayProvider,
        decoder: JSONDecoder
    ) async throws -> String {
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (field, value) in provider.extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withAITimeout {
                try await aiURLSession.data(for: request)
            }
        } catch {
            let mapped = AIServiceError.from(error)
            mapped.logForDeveloper(context: "\(provider.displayName) network request")
            throw mapped
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkFailure
        }
        guard (200..<300).contains(http.statusCode) else {
            let mapped: AIServiceError
            switch http.statusCode {
            case 401, 403: mapped = .invalidAPIKey
            case 429: mapped = .rateLimited
            default: mapped = .requestFailed(provider: provider.displayName, status: http.statusCode)
            }
            mapped.logForDeveloper(context: "\(provider.displayName) HTTP \(http.statusCode)")
            throw mapped
        }

        let completion: BazaarLinkResponse
        do {
            completion = try decoder.decode(BazaarLinkResponse.self, from: data)
        } catch {
            AIServiceError.invalidResponse.logForDeveloper(context: "decoding chat completion")
            throw AIServiceError.invalidResponse
        }
        guard let content = completion.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return content
    }

    private static let systemPrompt = """
    You organize one raw personal memory ("Had coffee with Jimmy, he's applying to Stripe, remind me Friday to send the intro") into strict JSON for a local-first relationship-memory iOS app. Return only JSON, nothing else.

    Rules:
    - Extract only facts actually stated or strongly implied by the input. Never invent facts, names, or dates.
    - The narrator is the app's user ("I"/"me"). Everyone else mentioned is a contact. Facts, interests, and dislikes belong to the CONTACT they are about, never to the user. If the user describes their own interests or plans, do not report them as the contact's.
    - Distinguish explicit commands ("remind me Friday", "follow up next week about X") from merely implied follow-ups; explicit ones go in "reminders", implied ones in "impliedFollowUps".
    - Resolve relative dates ("Friday", "tomorrow", "next Tuesday", "in two weeks") against the capture date and timezone provided. Use ISO-8601. If a date cannot be resolved with certainty, use null; never guess or invent a year, month, or day.
    - Do not duplicate the same fact across multiple categories.
    - Attribution matters: when more than one contact is named, each individual fact ("attributedFacts" entries, and each reminder/importantDate) must list exactly the person or people that specific fact is actually about in "personNames", never all contacts mentioned anywhere in the memory. If a fact doesn't clearly belong to anyone in particular, leave "personNames" empty; do not guess by picking whichever person was mentioned first.
    - Include a 0.0–1.0 confidence per category in "fieldConfidence" plus an overall "confidenceScore".
    """

    private static let extractionISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func userPrompt(text: String, knownPeople: [String], context: AIExtractionContext) -> String {
        var contextLines: [String] = []
        contextLines.append("Capture date: \(extractionISOFormatter.string(from: context.captureDate))")
        contextLines.append("Timezone: \(context.timeZoneID)")
        if !context.trustedPersonNames.isEmpty {
            contextLines.append("Trusted people this memory is about (already confirmed): \(context.trustedPersonNames.joined(separator: ", "))")
        }
        if !context.aliases.isEmpty {
            let pairs = context.aliases.map { "\($0.key) = \($0.value)" }.joined(separator: "; ")
            contextLines.append("Known nicknames: \(pairs)")
        }
        if let eventName = context.eventName, !eventName.isEmpty {
            contextLines.append("Trusted event this happened at: \(eventName)")
        }
        if !context.existingFacts.isEmpty {
            contextLines.append("Facts already on file (do not repeat these): \(context.existingFacts.prefix(30).joined(separator: "; "))")
        }

        return """
        \(contextLines.joined(separator: "\n"))
        Known people in the app: \(knownPeople.joined(separator: ", "))

        Raw memory:
        \(text)

        Return this JSON shape:
        {
          "summary": "short useful summary",
          "peopleMentioned": ["every person named in the memory, matching known names when possible, otherwise as written"],
          "topics": ["topic labels"],
          "interests": ["the contact's interests"],
          "dislikes": ["the contact's dislikes"],
          "schoolOrWorkFacts": ["school/work facts about the contact, e.g. 'Applying to Stripe'"],
          "locationFacts": ["location facts about the contact, e.g. 'Moving to New York in September'"],
          "familyFacts": ["family or relationship facts about the contact"],
          "giftIdeas": ["things the contact explicitly wants or would love"],
          "importantDates": [{"title": "Birthday", "date": "2026-07-04T00:00:00Z or null when uncertain", "display": "Birthday: July 4", "personNames": ["exactly who this date is about"]}],
          "reminders": [{"title": "Send the intro", "dueDate": "resolved ISO-8601 date or null if unresolvable", "personNames": ["exactly who this reminder is about"]}],
          "impliedFollowUps": ["possible follow-ups that were implied but never explicitly requested"],
          "followUpQuestions": ["questions to ask next time"],
          "personalityNotes": ["stable personality/communication notes about the contact"],
          "attributedFacts": [{"factType": "one of interest|dislike|schoolOrWork|location|family|personality|giftIdea", "value": "the fact, matching one of the arrays above", "personNames": ["exactly who this specific fact is about; empty if unclear"]}],
          "inferredInteractionType": "one of inPerson|call|message|videoCall|event|email, or null if unstated",
          "inferredDate": "ISO-8601 datetime the interaction happened, resolved against the capture date, or null if unstated",
          "explicitSentiment": "one of bad|neutral|good|great ONLY if the user explicitly said how it went, else null",
          "fieldConfidence": {"people": 0.0, "interests": 0.0, "reminders": 0.0, "importantDates": 0.0, "date": 0.0, "type": 0.0, "sentiment": 0.0},
          "confidenceScore": 0.0
        }

        "attributedFacts" must include one entry for every item already listed in interests/dislikes/schoolOrWorkFacts/locationFacts/familyFacts/personalityNotes/giftIdeas, with the matching factType and the correct personNames for that specific item.
        """
    }

    private static func decodeExtraction(from content: String, decoder: JSONDecoder) throws -> AIExtraction {
        if let data = content.data(using: .utf8),
           let extraction = try? decoder.decode(AIExtraction.self, from: data) {
            return extraction
        }
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}") else {
            throw AIServiceError.invalidResponse
        }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8) else { throw AIServiceError.invalidResponse }
        return try decoder.decode(AIExtraction.self, from: data)
    }

    func suggestGiftIdeas(personContext: String, existingGiftTitles: [String]) async throws -> [GiftSuggestion] {
        let model = UserDefaults.standard.string(forKey: "bazaarLinkModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await Self.send(modelOverride: model, decoder: decoder) { resolvedModel in
            BazaarLinkRequest(
                model: resolvedModel,
                messages: [
                    .init(role: "system", content: Self.giftSystemPrompt),
                    .init(role: "user", content: Self.giftUserPrompt(personContext: personContext, existingGiftTitles: existingGiftTitles)),
                ],
                temperature: 0.5,
                responseFormat: .init(type: "json_object")
            )
        }
        return try Self.decodeGiftSuggestions(from: result.content, decoder: decoder)
    }

    /// Plain-text relationship summary: no JSON schema, just a few honest
    /// sentences grounded in what's already logged for this person.
    func summarizePerson(context personContext: String) async throws -> String {
        let model = UserDefaults.standard.string(forKey: "bazaarLinkModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await Self.send(modelOverride: model, decoder: decoder) { resolvedModel in
            BazaarLinkRequest(
                model: resolvedModel,
                messages: [
                    .init(role: "system", content: Self.summarySystemPrompt),
                    .init(role: "user", content: personContext),
                ],
                temperature: 0.4,
                responseFormat: nil
            )
        }
        return result.content
    }

    /// Verifies whichever gateway key actually works; used by Settings'
    /// "Test Connection" button so a bad key or model ID surfaces
    /// immediately instead of only on the next note extraction or
    /// gift-idea request.
    func testConnection() async throws -> String {
        let model = UserDefaults.standard.string(forKey: "bazaarLinkModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await Self.send(modelOverride: model, decoder: decoder) { resolvedModel in
            BazaarLinkRequest(
                model: resolvedModel,
                messages: [.init(role: "user", content: "Reply with the single word: ok")],
                temperature: 0.2,
                responseFormat: nil
            )
        }
        return "Connected via \(result.provider.displayName) (\(result.model)). Replied: \(result.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))"
    }

    private static let summarySystemPrompt = """
    You write a short, honest relationship summary (3-5 sentences, plain text, no markdown) for a local-first iOS app, grounded strictly in the facts given. Mention how things have been going, the general tone, and one concrete suggested next move. Do not invent facts that aren't in the context.
    """

    // MARK: Fit Checker (vision)

    /// Rates a single outfit photo against the specific event it's headed
    /// to. Event-prep assistance only: the result is never persisted onto
    /// a `Person` or `Interaction`, so it can't touch closeness or history.
    func checkFit(image: UIImage, eventContext: String) async throws -> FitCheckResult {
        guard let dataURL = ImageEncoding.dataURL(for: image) else { throw AIServiceError.invalidResponse }
        let model = UserDefaults.standard.string(forKey: "bazaarLinkModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await Self.send(modelOverride: model, decoder: decoder) { resolvedModel in
            VisionRequest(
                model: resolvedModel,
                messages: [
                    VisionMessage(role: "system", content: [VisionContentPart.text(Self.fitCheckSystemPrompt)]),
                    VisionMessage(role: "user", content: [VisionContentPart.text(Self.fitCheckUserPrompt(eventContext: eventContext)), VisionContentPart.imageURL(dataURL)]),
                ],
                temperature: 0.4,
                responseFormat: ResponseFormat(type: "json_object")
            )
        }
        return try Self.decode(FitCheckResult.self, from: result.content, decoder: decoder)
    }

    private static let fitCheckSystemPrompt = """
    You are a sharp, honest personal stylist embedded in a private local-first relationship app called Social Climber. You are given one photo of an outfit and the details of a specific social event it's being worn to. Return only JSON. Be direct and concrete, never generic filler like "just be yourself" or "wear something nice". Ground every point strictly in what is actually visible in the photo (fit, color, layering, formality, condition) and in the event details given. Never invent details about the photo you can't actually see.
    """

    private static func fitCheckUserPrompt(eventContext: String) -> String {
        """
        Event context:
        \(eventContext)

        Rate how well the outfit in the photo fits this specific event: its formality, its social context, and the people involved. Return this JSON shape:
        {
          "score": 0-100 integer overall fit score,
          "verdict": "one short, punchy sentence verdict",
          "strengths": ["specific strengths actually visible in the photo"],
          "weaknesses": ["specific weak points: call out plainly if it reads too casual, too formal, too boring, too loud, or mismatched for this event"],
          "improvements": ["specific, actionable swaps or additions to make before going, not vague advice"],
          "confidence": 0.0-1.0 how confident you are given the photo's quality, angle, and lighting
        }
        """
    }

    // MARK: How to Respond (vision)

    /// Reads one or more conversation screenshots and suggests how to reply,
    /// grounded in what Social Climber already knows about this specific
    /// person. Assist-only: never creates an `Interaction` or touches
    /// closeness; the caller must not persist the screenshots either.
    func analyzeReply(images: [UIImage], personContext: String) async throws -> ReplyAdvice {
        let dataURLs = images.compactMap { ImageEncoding.dataURL(for: $0) }
        guard !dataURLs.isEmpty else { throw AIServiceError.invalidResponse }
        let model = UserDefaults.standard.string(forKey: "bazaarLinkModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var userContent: [VisionContentPart] = [VisionContentPart.text(Self.replyUserPrompt(personContext: personContext))]
        userContent.append(contentsOf: dataURLs.map { VisionContentPart.imageURL($0) })
        let result = try await Self.send(modelOverride: model, decoder: decoder) { resolvedModel in
            VisionRequest(
                model: resolvedModel,
                messages: [
                    VisionMessage(role: "system", content: [VisionContentPart.text(Self.replySystemPrompt)]),
                    VisionMessage(role: "user", content: userContent),
                ],
                temperature: 0.5,
                responseFormat: ResponseFormat(type: "json_object")
            )
        }
        return try Self.decode(ReplyAdvice.self, from: result.content, decoder: decoder)
    }

    private static let replySystemPrompt = """
    You are embedded in a private local-first relationship app called Social Climber. Given one or more screenshots of an incoming conversation, plus everything the app already knows about this specific person, you help the user decide how to reply. Return only JSON. Read the actual message text in the screenshot(s) carefully. Your recommended reply should respond to what was actually said, not something generic. Ground the tone and content of every reply in the person's real profile data given (closeness, notes, history) rather than generic advice. Never suggest anything as vague as "just be yourself"; give a reply the user could send as-is.
    """

    private static func replyUserPrompt(personContext: String) -> String {
        """
        Person context:
        \(personContext)

        Read the attached screenshot(s) of the incoming conversation, in order, and figure out what the other person most recently said or asked. Then return this JSON shape:
        {
          "recommendedReply": "a reply the user could send as-is, matched to the right tone (casual, funny, direct, warm, flirty, professional, distant, concise, or whichever actually fits) for this specific person and message",
          "alternates": [{"text": "an alternative reply", "why": "when or why you'd send this one instead"}],
          "explanation": "why the recommended reply fits, referencing the person's profile and the incoming message's tone",
          "tone": "short label for the tone used, e.g. 'Warm and casual' or 'Direct and professional'",
          "warning": "a short flag if the incoming message seems sensitive, risky, dry, hostile, or ambiguous; omit or null otherwise"
        }

        Give 1 to 3 alternates.
        """
    }

    private static let giftSystemPrompt = """
    You suggest thoughtful gift ideas for a local-first relationship app. Return only JSON. Ground every idea strictly in the facts given about the person: their interests, notes, tags, past interactions, and events. Do not invent specific personal facts (brands, sizes, exact preferences) that aren't implied by the given context; if the context is thin, suggest a more general idea tied to what is known instead of fabricating detail.
    """

    private static func giftUserPrompt(personContext: String, existingGiftTitles: [String]) -> String {
        """
        Person context:
        \(personContext)

        Gift ideas already suggested (do not repeat these): \(existingGiftTitles.isEmpty ? "none" : existingGiftTitles.joined(separator: ", "))

        Return this JSON shape:
        {
          "giftIdeas": [
            {"title": "short gift idea", "reason": "why it fits, referencing what's known about them", "priceRange": "$20-40", "occasion": "e.g. Birthday, or empty string if none"}
          ]
        }

        Suggest 3 to 5 ideas.
        """
    }

    private struct GiftSuggestionsResponse: Decodable {
        var giftIdeas: [GiftSuggestion]
    }

    private static func decodeGiftSuggestions(from content: String, decoder: JSONDecoder) throws -> [GiftSuggestion] {
        if let data = content.data(using: .utf8),
           let wrapper = try? decoder.decode(GiftSuggestionsResponse.self, from: data) {
            return wrapper.giftIdeas
        }
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}") else {
            throw AIServiceError.invalidResponse
        }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8) else { throw AIServiceError.invalidResponse }
        return try decoder.decode(GiftSuggestionsResponse.self, from: data).giftIdeas
    }

    /// Shared strict-JSON decoding for the vision responses (Fit Checker,
    /// How to Respond): tries the raw content first, then falls back to the
    /// substring between the first `{` and last `}` in case the model
    /// wrapped the JSON in prose or a code fence despite the JSON-mode ask.
    private static func decode<T: Decodable>(_ type: T.Type, from content: String, decoder: JSONDecoder) throws -> T {
        if let data = content.data(using: .utf8), let value = try? decoder.decode(T.self, from: data) {
            return value
        }
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}") else {
            throw AIServiceError.invalidResponse
        }
        let json = String(content[start...end])
        guard let data = json.data(using: .utf8) else { throw AIServiceError.invalidResponse }
        return try decoder.decode(T.self, from: data)
    }

    /// A chat completion request whose user message can include image parts:
    /// the vision counterpart to `BazaarLinkRequest`'s plain-string
    /// messages, used only by the Fit Checker and How to Respond calls.
    private struct VisionRequest: Encodable {
        let model: String
        let messages: [VisionMessage]
        let temperature: Double
        let responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case responseFormat = "response_format"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(temperature, forKey: .temperature)
            try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        }
    }

    private struct VisionMessage: Encodable {
        let role: String
        let content: [VisionContentPart]
    }

    /// One part of a multipart vision message: either plain text or an
    /// inline base64 image, matching BazaarLink/OpenAI's `content` array
    /// shape for chat completions.
    private enum VisionContentPart: Encodable {
        case text(String)
        case imageURL(String)

        private enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
        private struct ImageURLBox: Encodable { let url: String }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURLBox(url: url), forKey: .imageURL)
            }
        }
    }

    private struct BazaarLinkRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        /// `nil` for plain-text completions (e.g. the person summary), which
        /// don't ask the model for strict JSON.
        let responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case responseFormat = "response_format"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(temperature, forKey: .temperature)
            try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ResponseFormat: Encodable {
        let type: String
    }

    private struct BazaarLinkResponse: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let message: Message
    }
}

enum BazaarLinkDefaults {
    /// The initial value shown in Settings' shared model-override field
    /// before the user types anything. Leaving the field blank (its usual
    /// state) makes each gateway resolve its own free-routing default
    /// instead; see `AIGatewayProvider.defaultFreeModel`. Free-tier models
    /// aren't guaranteed to be vision-capable, so Fit Checker / How to
    /// Respond (photo features) may need a real vision model ID set here.
    static let modelID = "auto:free"
}

// MARK: - Mock implementation

/// Deterministic keyword/heuristic extraction so the whole AI flow works
/// offline with zero dependencies.
final class MockAIService: AIService {

    private static let topicKeywords: [String: [String]] = [
        "Career": ["job", "internship", "interview", "career", "offer", "recruiting", "work", "startup", "promotion", "resume"],
        "School": ["class", "exam", "midterm", "final", "professor", "homework", "semester", "berkeley", "ucc", "study", "course"],
        "Travel": ["trip", "travel", "flight", "vacation", "visit", "abroad", "japan", "europe", "roadtrip"],
        "Food": ["dinner", "lunch", "restaurant", "coffee", "boba", "cooking", "food", "brunch", "ramen"],
        "Sports": ["gym", "basketball", "soccer", "climbing", "run", "running", "f1", "formula 1", "tennis", "ski", "hike", "hiking", "workout"],
        "Family": ["mom", "dad", "sister", "brother", "parents", "family", "grandma", "grandpa", "cousin"],
        "Health": ["sick", "doctor", "health", "injury", "surgery", "therapy", "stressed"],
        "Relationships": ["dating", "girlfriend", "boyfriend", "breakup", "wedding", "engaged"],
        "Gaming": ["game", "gaming", "valorant", "league", "switch", "playstation"],
        "Music": ["concert", "music", "album", "spotify", "playlist", "festival"],
        "Movies & TV": ["movie", "film", "show", "series", "netflix", "anime"],
        "Money": ["rent", "salary", "investing", "stocks", "crypto", "budget"],
    ]

    private static let interestMarkers = ["loves ", "likes ", "is into ", "enjoys ", "obsessed with ", "big fan of ", "really into ", "passionate about ", "started "]
    private static let dislikeMarkers = ["hates ", "doesn't like ", "does not like ", "can't stand ", "dislikes ", "is sick of ", "is tired of "]
    private static let giftMarkers = ["wants ", "wishlist", "gift idea", "would love ", "has been eyeing ", "asked for ", "needs a new ", "get them ", "get her ", "get him "]
    private static let schoolWorkMarkers = ["applying to ", "works at ", "working at ", "new job at ", "joined ", "is joining ", "interning at ", "studying ", "studies ", "majoring in "]
    private static let locationMarkers = ["moving to ", "moved to ", "lives in ", "living in ", "relocating to "]
    private static let familyMarkers = ["her sister", "his sister", "her brother", "his brother", "her mom", "his mom", "her dad", "his dad", "their kids", "her husband", "his wife", "her boyfriend", "his girlfriend", "got engaged", "getting married"]
    private static let reminderMarkers = ["follow up", "remind me", "should reach out", "need to", "i should", "don't forget", "check in", "circle back", "send them", "ask them", "send this by", "send him", "send her"]
    /// Markers that make a follow-up an explicit instruction rather than a
    /// vague intention; only these schedule a real reminder.
    private static let explicitReminderMarkers = ["remind me", "follow up", "don't forget", "send this by", "circle back"]
    private static let personalityMarkers = ["seems ", "is very ", "is super ", "is kind of ", "personality", "always ", "tends to ", "is a ", "kept interrupting"]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    func extract(from text: String, knownPeople: [String], context: AIExtractionContext) async throws -> AIExtraction {
        // Small delay so the UI's "analyzing" state is visible and honest.
        try? await Task.sleep(for: .milliseconds(600))

        var result = AIExtraction()
        let lower = text.lowercased()
        let sentences = Self.sentences(in: text)
        let reference = context.captureDate

        // People: known names mentioned in the text (full name or first name).
        result.peopleMentioned = knownPeople.filter { name in
            let first = name.components(separatedBy: " ").first ?? name
            return lower.contains(name.lowercased()) || lower.contains(first.lowercased())
        }
        for trusted in context.trustedPersonNames where !result.peopleMentioned.contains(trusted) {
            result.peopleMentioned.append(trusted)
        }

        // Topics from keyword buckets.
        result.topics = Self.topicKeywords.compactMap { topic, words in
            words.contains { lower.contains($0) } ? topic : nil
        }.sorted()

        // Interaction shape: type, date, and only *explicit* sentiment.
        result.inferredInteractionType = CaptureParser.inferInteractionType(in: text)?.rawValue
        result.inferredDate = CaptureParser.inferInteractionDate(in: text, reference: reference)
        result.explicitSentiment = CaptureParser.explicitSentiment(in: text).map { sentiment in
            switch sentiment {
            case .bad: "bad"
            case .neutral: "neutral"
            case .good: "good"
            case .great: "great"
            }
        }

        // Per-sentence attribution: which known people this specific
        // sentence names, so a fact never defaults to "whoever was resolved
        // first" for the whole capture; see `ExtractedFact`.
        var attributed: [ExtractedFact] = []

        for sentence in sentences {
            let sLower = sentence.lowercased()
            let namesHere = CaptureParser.peopleNamed(in: sentence, knownPeople: knownPeople)

            for marker in Self.interestMarkers {
                if let phrase = Self.phrase(after: marker, in: sentence) {
                    result.interests.append(phrase)
                    attributed.append(ExtractedFact(factType: MemoryFactType.interest.rawValue, value: phrase, personNames: namesHere))
                }
            }
            for marker in Self.dislikeMarkers {
                if let phrase = Self.phrase(after: marker, in: sentence) {
                    result.dislikes.append(phrase)
                    attributed.append(ExtractedFact(factType: MemoryFactType.dislike.rawValue, value: phrase, personNames: namesHere))
                }
            }
            for marker in Self.giftMarkers {
                if let phrase = Self.phrase(after: marker, in: sentence) {
                    result.giftIdeas.append(phrase)
                    attributed.append(ExtractedFact(factType: MemoryFactType.giftIdea.rawValue, value: phrase, personNames: namesHere))
                }
            }
            for marker in Self.schoolWorkMarkers {
                if Self.phrase(after: marker, in: sentence) != nil {
                    let value = Self.clean(sentence)
                    result.schoolOrWorkFacts.append(value)
                    attributed.append(ExtractedFact(factType: MemoryFactType.schoolOrWork.rawValue, value: value, personNames: namesHere))
                    break
                }
            }
            for marker in Self.locationMarkers {
                if Self.phrase(after: marker, in: sentence) != nil {
                    let value = Self.clean(sentence)
                    result.locationFacts.append(value)
                    attributed.append(ExtractedFact(factType: MemoryFactType.location.rawValue, value: value, personNames: namesHere))
                    break
                }
            }
            if Self.familyMarkers.contains(where: { sLower.contains($0) }) {
                let value = Self.clean(sentence)
                result.familyFacts.append(value)
                attributed.append(ExtractedFact(factType: MemoryFactType.family.rawValue, value: value, personNames: namesHere))
            }
            if Self.reminderMarkers.contains(where: { sLower.contains($0) }) {
                if Self.explicitReminderMarkers.contains(where: { sLower.contains($0) }) {
                    // Anchor relative phrases ("Friday", "next week") to the
                    // capture date; leave the due date nil when the sentence
                    // names no resolvable day. Never invent a fallback date.
                    result.reminders.append(ExtractedReminder(
                        title: Self.clean(sentence),
                        dueDate: CaptureParser.resolveRelativeDate(in: sentence, reference: reference),
                        personNames: namesHere
                    ))
                } else {
                    result.impliedFollowUps.append(Self.clean(sentence))
                }
            }
            if Self.personalityMarkers.contains(where: { sLower.contains($0) }),
               result.peopleMentioned.contains(where: { sLower.contains($0.components(separatedBy: " ").first!.lowercased()) }) {
                let value = Self.clean(sentence)
                result.personalityNotes.append(value)
                attributed.append(ExtractedFact(factType: MemoryFactType.personality.rawValue, value: value, personNames: namesHere))
            }
            // Dates: "birthday ... <month> <day>" or plain "<month> <day>"
            if var extracted = Self.date(in: sentence) {
                extracted.personNames = namesHere
                result.importantDates.append(extracted)
            }
        }

        result.interests = Array(Set(result.interests)).sorted()
        result.dislikes = Array(Set(result.dislikes)).sorted()
        result.giftIdeas = Array(Set(result.giftIdeas)).sorted()
        result.schoolOrWorkFacts = Array(Set(result.schoolOrWorkFacts)).sorted()
        result.locationFacts = Array(Set(result.locationFacts)).sorted()
        result.familyFacts = Array(Set(result.familyFacts)).sorted()
        // Deduped by (type, value, attributed people) rather than value
        // alone, so the same phrase said about two different people (or
        // about no one in particular) survives as distinct facts.
        var seenAttributed = Set<String>()
        result.attributedFacts = attributed.filter { fact in
            let key = "\(fact.factType)|\(fact.value.lowercased())|\(fact.personNames.sorted().joined(separator: ","))"
            return seenAttributed.insert(key).inserted
        }

        // Follow-up questions generated from detected topics.
        result.followUpQuestions = result.topics.prefix(3).map { topic in
            switch topic {
            case "Career": "Ask how the job/internship search is going"
            case "School": "Ask how classes and exams went"
            case "Travel": "Ask about the trip they mentioned"
            case "Health": "Check how they're feeling"
            case "Family": "Ask how their family is doing"
            case "Relationships": "Ask how things are going with their relationship"
            default: "Ask a follow-up about \(topic.lowercased())"
            }
        }

        // Summary: first two sentences, tidied.
        result.summary = sentences.prefix(2).map(Self.clean).joined(separator: " ")
        if result.summary.isEmpty { result.summary = Self.clean(text) }

        let signal = result.topics.count + result.interests.count + result.giftIdeas.count
            + result.reminders.count + result.peopleMentioned.count
            + result.dislikes.count + result.schoolOrWorkFacts.count + result.locationFacts.count
        result.confidence = min(0.95, 0.4 + Double(signal) * 0.06)
        // Heuristic extraction is deliberately conservative: whatever it did
        // find came from explicit marker phrases, so those categories carry
        // more confidence than the overall guess.
        result.fieldConfidence = [
            "people": result.peopleMentioned.isEmpty ? 0.2 : 0.7,
            "reminders": result.reminders.isEmpty ? 0.2 : 0.85,
            "interests": result.interests.isEmpty ? 0.2 : 0.75,
            "importantDates": result.importantDates.isEmpty ? 0.2 : 0.6,
            "date": result.inferredDate == nil ? 0.2 : 0.8,
            "type": result.inferredInteractionType == nil ? 0.2 : 0.8,
            "sentiment": result.explicitSentiment == nil ? 0.2 : 0.85,
        ]

        return result
    }

    // MARK: helpers

    private static func sentences(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 }
    }

    /// The words following a marker, capped at 6 words, trimmed of trailing filler.
    private static func phrase(after marker: String, in sentence: String) -> String? {
        let lower = sentence.lowercased()
        guard let range = lower.range(of: marker) else { return nil }
        let tail = String(sentence[range.upperBound...])
        var words = tail.components(separatedBy: " ").filter { !$0.isEmpty }
        if words.isEmpty { return nil }
        words = Array(words.prefix(6))
        let stopWords = ["and", "but", "so", "because", "which", "though", "when", "the", "a", "to"]
        while let last = words.last?.lowercased(), stopWords.contains(last) { words.removeLast() }
        let phrase = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        return phrase.count > 2 ? phrase.capitalizedFirst : nil
    }

    private static func date(in sentence: String) -> ExtractedDate? {
        let lower = sentence.lowercased()
        for (index, month) in months.enumerated() {
            guard let monthRange = lower.range(of: month) else { continue }
            let tail = lower[monthRange.upperBound...].trimmingCharacters(in: .whitespaces)
            let dayString = tail.prefix { $0.isNumber }
            var comps = DateComponents()
            comps.month = index + 1
            comps.day = Int(dayString) ?? 1
            comps.year = Calendar.current.component(.year, from: .now)
            let date = Calendar.current.date(from: comps)
            let title = lower.contains("birthday") ? "Birthday"
                : lower.contains("anniversary") ? "Anniversary"
                : lower.contains("graduat") ? "Graduation"
                : "Important date"
            let display = "\(title): \(month.capitalized) \(dayString.isEmpty ? "" : String(dayString))"
                .trimmingCharacters(in: .whitespaces)
            return ExtractedDate(title: title, date: date, display: display)
        }
        return nil
    }

    private static func clean(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: .whitespacesAndNewlines).capitalizedFirst
    }

    /// Deterministic offline fallback: pulls interests straight out of the
    /// context text Social Climber already built and turns them into
    /// generic, honest suggestions. No fabricated specifics.
    func suggestGiftIdeas(personContext: String, existingGiftTitles: [String]) async throws -> [GiftSuggestion] {
        try? await Task.sleep(for: .milliseconds(400))

        var ideas: [GiftSuggestion] = []
        if let interestsLine = personContext
            .components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("Interests:") }) {
            let interests = interestsLine
                .replacingOccurrences(of: "Interests:", with: "")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for interest in interests.prefix(5) {
                guard !existingGiftTitles.contains(where: { $0.localizedCaseInsensitiveContains(interest) }) else { continue }
                ideas.append(GiftSuggestion(
                    title: "\(interest.capitalizedFirst)-themed gift",
                    reason: "They're into \(interest.lowercased()), based on what's logged for them.",
                    priceRange: "$20–50"
                ))
            }
        }

        if ideas.isEmpty {
            ideas.append(GiftSuggestion(
                title: "Handwritten card + a small treat",
                reason: "Not enough is logged yet to get more specific; log interests or interactions for better ideas.",
                priceRange: "$10–25"
            ))
        }

        return Array(ideas.prefix(5))
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
