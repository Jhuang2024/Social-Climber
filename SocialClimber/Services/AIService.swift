import Foundation

// MARK: - Extraction output

struct ExtractedDate: Codable, Hashable {
    var title: String
    var date: Date?
    var display: String
}

struct ExtractedReminder: Codable, Hashable {
    var title: String
    var dueDate: Date?
}

struct AIExtraction: Codable {
    var summary: String = ""
    var peopleMentioned: [String] = []
    var topics: [String] = []
    var interests: [String] = []
    var giftIdeas: [String] = []
    var importantDates: [ExtractedDate] = []
    var reminders: [ExtractedReminder] = []
    var followUpQuestions: [String] = []
    var personalityNotes: [String] = []
    var confidence: Double = 0.5

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
    }

    var isEmpty: Bool {
        topics.isEmpty && interests.isEmpty && giftIdeas.isEmpty
            && importantDates.isEmpty && reminders.isEmpty
            && followUpQuestions.isEmpty && personalityNotes.isEmpty
    }
}

// MARK: - Protocol

protocol AIService {
    func extract(from text: String, knownPeople: [String]) async throws -> AIExtraction
}

enum AIProvider: String, CaseIterable, Identifiable {
    case mock
    case openRouter

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mock: "Mock"
        case .openRouter: "OpenRouter"
        }
    }

    var service: AIService {
        switch self {
        case .mock: MockAIService()
        case .openRouter: OpenRouterAIService()
        }
    }

    static var current: AIService {
        let raw = UserDefaults.standard.string(forKey: "aiProvider") ?? AIProvider.mock.rawValue
        return (AIProvider(rawValue: raw) ?? .mock).service
    }
}

enum AIServiceError: LocalizedError {
    case missingOpenRouterAPIKey
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingOpenRouterAPIKey:
            "Add your OpenRouter API key in Settings, or switch AI Provider to Mock."
        case .invalidResponse:
            "The AI provider returned a response Social Climber could not read."
        case .emptyResponse:
            "The AI provider returned an empty response."
        }
    }
}

final class OpenRouterAIService: AIService {
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func extract(from text: String, knownPeople: [String]) async throws -> AIExtraction {
        let apiKey = try KeychainService.openRouterAPIKey()
        let model = UserDefaults.standard.string(forKey: "openRouterModelID")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestBody = OpenRouterRequest(
            model: model?.isEmpty == false ? model! : OpenRouterDefaults.modelID,
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: Self.userPrompt(text: text, knownPeople: knownPeople)),
            ],
            temperature: 0.2,
            responseFormat: .init(type: "json_object")
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return try await MockAIService().extract(from: text, knownPeople: knownPeople)
        }

        let completion = try decoder.decode(OpenRouterResponse.self, from: data)
        guard let content = completion.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }

        return try Self.decodeExtraction(from: content, decoder: decoder)
    }

    private static let systemPrompt = """
    You turn relationship notes into strict JSON for a local-first iOS app. Return only JSON. Use ISO-8601 dates when a date is clear. Use null for uncertain dates. Do not invent facts.
    """

    private static func userPrompt(text: String, knownPeople: [String]) -> String {
        """
        Known people: \(knownPeople.joined(separator: ", "))

        Raw note:
        \(text)

        Return this JSON shape:
        {
          "summary": "short useful summary",
          "peopleMentioned": ["matching known names"],
          "topics": ["topic labels"],
          "interests": ["interests to attach to the selected person"],
          "giftIdeas": ["gift ideas"],
          "importantDates": [{"title": "Birthday", "date": "2026-07-04T00:00:00Z", "display": "Birthday: July 4"}],
          "reminders": [{"title": "Follow up about...", "dueDate": "2026-07-07T09:00:00Z"}],
          "followUpQuestions": ["questions to ask next time"],
          "personalityNotes": ["stable personality/context notes"],
          "confidenceScore": 0.0
        }
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

    private struct OpenRouterRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let responseFormat: ResponseFormat

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case responseFormat = "response_format"
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ResponseFormat: Encodable {
        let type: String
    }

    private struct OpenRouterResponse: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let message: Message
    }
}

enum OpenRouterDefaults {
    static let modelID = "openrouter/free"
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
    private static let giftMarkers = ["wants ", "wishlist", "gift idea", "would love ", "has been eyeing ", "asked for ", "needs a new ", "get them ", "get her ", "get him "]
    private static let reminderMarkers = ["follow up", "remind me", "should reach out", "need to", "i should", "don't forget", "check in", "circle back", "send them", "ask them"]
    private static let personalityMarkers = ["seems ", "is very ", "is super ", "is kind of ", "personality", "always ", "tends to ", "is a "]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    func extract(from text: String, knownPeople: [String]) async throws -> AIExtraction {
        // Small delay so the UI's "analyzing" state is visible and honest.
        try? await Task.sleep(for: .milliseconds(600))

        var result = AIExtraction()
        let lower = text.lowercased()
        let sentences = Self.sentences(in: text)

        // People: known names mentioned in the text (full name or first name).
        result.peopleMentioned = knownPeople.filter { name in
            let first = name.components(separatedBy: " ").first ?? name
            return lower.contains(name.lowercased()) || lower.contains(first.lowercased())
        }

        // Topics from keyword buckets.
        result.topics = Self.topicKeywords.compactMap { topic, words in
            words.contains { lower.contains($0) } ? topic : nil
        }.sorted()

        for sentence in sentences {
            let sLower = sentence.lowercased()

            for marker in Self.interestMarkers {
                if let phrase = Self.phrase(after: marker, in: sentence) {
                    result.interests.append(phrase)
                }
            }
            for marker in Self.giftMarkers {
                if let phrase = Self.phrase(after: marker, in: sentence) {
                    result.giftIdeas.append(phrase)
                }
            }
            if Self.reminderMarkers.contains(where: { sLower.contains($0) }) {
                result.reminders.append(ExtractedReminder(
                    title: Self.clean(sentence),
                    dueDate: Calendar.current.date(byAdding: .day, value: sLower.contains("next week") ? 7 : 3, to: .now)
                ))
            }
            if Self.personalityMarkers.contains(where: { sLower.contains($0) }),
               result.peopleMentioned.contains(where: { sLower.contains($0.components(separatedBy: " ").first!.lowercased()) }) {
                result.personalityNotes.append(Self.clean(sentence))
            }
            // Dates: "birthday ... <month> <day>" or plain "<month> <day>"
            if let extracted = Self.date(in: sentence) {
                result.importantDates.append(extracted)
            }
        }

        result.interests = Array(Set(result.interests)).sorted()
        result.giftIdeas = Array(Set(result.giftIdeas)).sorted()

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
        result.confidence = min(0.95, 0.4 + Double(signal) * 0.06)

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
}

extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
