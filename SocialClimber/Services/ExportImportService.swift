import Foundation
import SwiftData

/// Decodes a value defensively: any decode failure (a missing key, the
/// wrong type, or the container itself throwing) falls back to `fallback`
/// instead of propagating, so one malformed or not-yet-invented field never
/// fails an entire archive or record. Shared by `Archive` and the DTOs
/// below so every backward-compatibility fallback uses the same rule.
private func decodeOrDefault<Key: CodingKey, T: Decodable>(_ container: KeyedDecodingContainer<Key>, _ key: Key, _ fallback: T) -> T {
    guard let value = try? container.decodeIfPresent(T.self, forKey: key) else { return fallback }
    return value ?? fallback
}

/// JSON export/import of the whole database. People are matched by name on
/// import, so re-importing a backup merges instead of duplicating. This is
/// also the format `BackupManager`'s automatic snapshots use, so every
/// safeguard here (defensive decoding of old/future files, never requiring
/// a field that didn't always exist) protects backups just as much as the
/// manual "Export JSON…" / "Import JSON…" flow.
enum ExportImportService {

    // MARK: DTOs

    struct Archive: Codable {
        var version = 3
        var exportedAt = Date()
        var people: [PersonDTO] = []
        var interactions: [InteractionDTO] = []
        var events: [EventDTO] = []
        var captures: [CaptureDTO] = []
        var memoryFacts: [FactDTO] = []

        init() {}

        private enum CodingKeys: String, CodingKey {
            case version, exportedAt, people, interactions, events, captures, memoryFacts
        }

        /// Every field decoded with a fallback to its default, so an older
        /// export (from before `events` — or `captures`/`memoryFacts` —
        /// existed) still restores everything it originally had, instead of
        /// failing the whole file over one missing key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = decodeOrDefault(c, .version, 1)
            exportedAt = decodeOrDefault(c, .exportedAt, Date())
            people = decodeOrDefault(c, .people, [])
            interactions = decodeOrDefault(c, .interactions, [])
            events = decodeOrDefault(c, .events, [])
            captures = decodeOrDefault(c, .captures, [])
            memoryFacts = decodeOrDefault(c, .memoryFacts, [])
        }
    }

    struct CaptureDTO: Codable {
        var uuid: UUID
        var rawText: String
        var transcript: String
        var ocrText: String
        var source: String
        var capturedAt: Date
        var trustedPersonIDs: [UUID]
        var trustedPersonNames: [String]
        var resolvedPersonIDs: [UUID]
        var resolvedPersonNames: [String]
        var candidatePersonIDs: [UUID]
        var candidatePersonNames: [String]
        var eventName: String
        var eventDate: Date?
        var eventLocation: String
        var typeHint: String
        var status: String
        var attempts: Int
        var errorMessage: String
        var inferenceConfidence: Double
        var usedLocalFallback: Bool
        var title: String
        var detail: String
        var createdAt: Date

        private enum CodingKeys: String, CodingKey {
            case uuid, rawText, transcript, ocrText, source, capturedAt
            case trustedPersonIDs, trustedPersonNames, resolvedPersonIDs, resolvedPersonNames
            case candidatePersonIDs, candidatePersonNames
            case eventName, eventDate, eventLocation, typeHint, status, attempts, errorMessage
            case inferenceConfidence, usedLocalFallback, title, detail, createdAt
        }

        init(
            uuid: UUID, rawText: String, transcript: String, ocrText: String, source: String, capturedAt: Date,
            trustedPersonIDs: [UUID], trustedPersonNames: [String],
            resolvedPersonIDs: [UUID], resolvedPersonNames: [String],
            candidatePersonIDs: [UUID], candidatePersonNames: [String],
            eventName: String, eventDate: Date?, eventLocation: String, typeHint: String, status: String,
            attempts: Int, errorMessage: String, inferenceConfidence: Double, usedLocalFallback: Bool,
            title: String, detail: String, createdAt: Date
        ) {
            self.uuid = uuid
            self.rawText = rawText
            self.transcript = transcript
            self.ocrText = ocrText
            self.source = source
            self.capturedAt = capturedAt
            self.trustedPersonIDs = trustedPersonIDs
            self.trustedPersonNames = trustedPersonNames
            self.resolvedPersonIDs = resolvedPersonIDs
            self.resolvedPersonNames = resolvedPersonNames
            self.candidatePersonIDs = candidatePersonIDs
            self.candidatePersonNames = candidatePersonNames
            self.eventName = eventName
            self.eventDate = eventDate
            self.eventLocation = eventLocation
            self.typeHint = typeHint
            self.status = status
            self.attempts = attempts
            self.errorMessage = errorMessage
            self.inferenceConfidence = inferenceConfidence
            self.usedLocalFallback = usedLocalFallback
            self.title = title
            self.detail = detail
            self.createdAt = createdAt
        }

        /// The ID arrays are decoded defensively so an export written before
        /// they existed still restores everything it originally had; a
        /// restore of such a file simply carries no authoritative IDs for
        /// that capture (its cached names still show correctly).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(UUID.self, forKey: .uuid)
            rawText = try c.decode(String.self, forKey: .rawText)
            transcript = try c.decode(String.self, forKey: .transcript)
            ocrText = try c.decode(String.self, forKey: .ocrText)
            source = try c.decode(String.self, forKey: .source)
            capturedAt = try c.decode(Date.self, forKey: .capturedAt)
            trustedPersonIDs = decodeOrDefault(c, .trustedPersonIDs, [])
            trustedPersonNames = try c.decode([String].self, forKey: .trustedPersonNames)
            resolvedPersonIDs = decodeOrDefault(c, .resolvedPersonIDs, [])
            resolvedPersonNames = try c.decode([String].self, forKey: .resolvedPersonNames)
            candidatePersonIDs = decodeOrDefault(c, .candidatePersonIDs, [])
            candidatePersonNames = try c.decode([String].self, forKey: .candidatePersonNames)
            eventName = try c.decode(String.self, forKey: .eventName)
            eventDate = try c.decodeIfPresent(Date.self, forKey: .eventDate)
            eventLocation = try c.decode(String.self, forKey: .eventLocation)
            typeHint = try c.decode(String.self, forKey: .typeHint)
            status = try c.decode(String.self, forKey: .status)
            attempts = try c.decode(Int.self, forKey: .attempts)
            errorMessage = try c.decode(String.self, forKey: .errorMessage)
            inferenceConfidence = try c.decode(Double.self, forKey: .inferenceConfidence)
            usedLocalFallback = try c.decode(Bool.self, forKey: .usedLocalFallback)
            title = try c.decode(String.self, forKey: .title)
            detail = try c.decode(String.self, forKey: .detail)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
        }
    }

    struct FactDTO: Codable {
        var type: String
        var value: String
        var dateValue: Date?
        var confidence: Double
        var status: String
        var origin: String
        var personUUID: UUID?
        var personName: String?
        var sourceCaptureUUID: UUID?
        var sourceInteractionUUID: UUID?
        var createdAt: Date
        var rejectedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case type, value, dateValue, confidence, status, origin
            case personUUID, personName, sourceCaptureUUID, sourceInteractionUUID
            case createdAt, rejectedAt
        }

        init(
            type: String, value: String, dateValue: Date?, confidence: Double, status: String, origin: String,
            personUUID: UUID?, personName: String?, sourceCaptureUUID: UUID?, sourceInteractionUUID: UUID?,
            createdAt: Date, rejectedAt: Date?
        ) {
            self.type = type
            self.value = value
            self.dateValue = dateValue
            self.confidence = confidence
            self.status = status
            self.origin = origin
            self.personUUID = personUUID
            self.personName = personName
            self.sourceCaptureUUID = sourceCaptureUUID
            self.sourceInteractionUUID = sourceInteractionUUID
            self.createdAt = createdAt
            self.rejectedAt = rejectedAt
        }

        /// `origin`/`personUUID`/`sourceInteractionUUID` are decoded
        /// defensively so a fact exported before they existed still
        /// restores in full.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            value = try c.decode(String.self, forKey: .value)
            dateValue = try c.decodeIfPresent(Date.self, forKey: .dateValue)
            confidence = try c.decode(Double.self, forKey: .confidence)
            status = try c.decode(String.self, forKey: .status)
            origin = decodeOrDefault(c, .origin, MemoryFactOrigin.machine.rawValue)
            personUUID = (try? c.decodeIfPresent(UUID.self, forKey: .personUUID)) ?? nil
            personName = (try? c.decodeIfPresent(String.self, forKey: .personName)) ?? nil
            sourceCaptureUUID = (try? c.decodeIfPresent(UUID.self, forKey: .sourceCaptureUUID)) ?? nil
            sourceInteractionUUID = (try? c.decodeIfPresent(UUID.self, forKey: .sourceInteractionUUID)) ?? nil
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            rejectedAt = try c.decodeIfPresent(Date.self, forKey: .rejectedAt)
        }
    }

    struct PersonDTO: Codable {
        /// Stable identity so capture/fact provenance created on this device
        /// keeps pointing at the right person across export/restore. `nil`
        /// only when decoding a pre-`Person.uuid` export; import then
        /// leaves an existing matched person's own `uuid` untouched (never
        /// overwritten by an imported value) and assigns a fresh one only
        /// when creating a brand-new person.
        var uuid: UUID?
        var name: String
        var nickname: String
        var relationshipToMe: String
        var category: String
        var closeness: Int
        var priority: Int
        var birthday: Date?
        var lastContactedAt: Date?
        var lastMetAt: Date?
        var lastMessagedAt: Date?
        var lastCalledAt: Date?
        var isArchived: Bool
        var checkInCadenceDays: Int?
        var notes: String
        var personalityNotes: String
        var interests: [String]
        var dislikes: [String]
        var familyMembers: [String]
        var schoolOrWork: String
        var location: String
        var contactMethods: [ContactMethod]
        var tags: [String]
        var avatarData: Data?
        var giftIdeas: [GiftDTO]
        var reminders: [ReminderDTO]
        var importantDates: [DateDTO]

        private enum CodingKeys: String, CodingKey {
            case uuid, name, nickname, relationshipToMe, category, closeness, priority, birthday
            case lastContactedAt, lastMetAt, lastMessagedAt, lastCalledAt, isArchived, checkInCadenceDays
            case notes, personalityNotes, interests, dislikes, familyMembers, schoolOrWork, location
            case contactMethods, tags, avatarData, giftIdeas, reminders, importantDates
        }

        init(
            uuid: UUID?, name: String, nickname: String, relationshipToMe: String, category: String,
            closeness: Int, priority: Int, birthday: Date?, lastContactedAt: Date?, lastMetAt: Date?,
            lastMessagedAt: Date?, lastCalledAt: Date?, isArchived: Bool, checkInCadenceDays: Int?,
            notes: String, personalityNotes: String, interests: [String], dislikes: [String],
            familyMembers: [String], schoolOrWork: String, location: String, contactMethods: [ContactMethod],
            tags: [String], avatarData: Data?, giftIdeas: [GiftDTO], reminders: [ReminderDTO], importantDates: [DateDTO]
        ) {
            self.uuid = uuid
            self.name = name
            self.nickname = nickname
            self.relationshipToMe = relationshipToMe
            self.category = category
            self.closeness = closeness
            self.priority = priority
            self.birthday = birthday
            self.lastContactedAt = lastContactedAt
            self.lastMetAt = lastMetAt
            self.lastMessagedAt = lastMessagedAt
            self.lastCalledAt = lastCalledAt
            self.isArchived = isArchived
            self.checkInCadenceDays = checkInCadenceDays
            self.notes = notes
            self.personalityNotes = personalityNotes
            self.interests = interests
            self.dislikes = dislikes
            self.familyMembers = familyMembers
            self.schoolOrWork = schoolOrWork
            self.location = location
            self.contactMethods = contactMethods
            self.tags = tags
            self.avatarData = avatarData
            self.giftIdeas = giftIdeas
            self.reminders = reminders
            self.importantDates = importantDates
        }

        /// Every field here is required exactly as before except `uuid`,
        /// added alongside the capture-first redesign — decoded
        /// defensively so an export written before it existed still
        /// restores in full.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = (try? c.decodeIfPresent(UUID.self, forKey: .uuid)) ?? nil
            name = try c.decode(String.self, forKey: .name)
            nickname = try c.decode(String.self, forKey: .nickname)
            relationshipToMe = try c.decode(String.self, forKey: .relationshipToMe)
            category = try c.decode(String.self, forKey: .category)
            closeness = try c.decode(Int.self, forKey: .closeness)
            priority = try c.decode(Int.self, forKey: .priority)
            birthday = try c.decodeIfPresent(Date.self, forKey: .birthday)
            lastContactedAt = try c.decodeIfPresent(Date.self, forKey: .lastContactedAt)
            lastMetAt = try c.decodeIfPresent(Date.self, forKey: .lastMetAt)
            lastMessagedAt = try c.decodeIfPresent(Date.self, forKey: .lastMessagedAt)
            lastCalledAt = try c.decodeIfPresent(Date.self, forKey: .lastCalledAt)
            isArchived = try c.decode(Bool.self, forKey: .isArchived)
            checkInCadenceDays = try c.decodeIfPresent(Int.self, forKey: .checkInCadenceDays)
            notes = try c.decode(String.self, forKey: .notes)
            personalityNotes = try c.decode(String.self, forKey: .personalityNotes)
            interests = try c.decode([String].self, forKey: .interests)
            dislikes = try c.decode([String].self, forKey: .dislikes)
            familyMembers = try c.decode([String].self, forKey: .familyMembers)
            schoolOrWork = try c.decode(String.self, forKey: .schoolOrWork)
            location = try c.decode(String.self, forKey: .location)
            contactMethods = try c.decode([ContactMethod].self, forKey: .contactMethods)
            tags = try c.decode([String].self, forKey: .tags)
            avatarData = try c.decodeIfPresent(Data.self, forKey: .avatarData)
            giftIdeas = try c.decode([GiftDTO].self, forKey: .giftIdeas)
            reminders = try c.decode([ReminderDTO].self, forKey: .reminders)
            importantDates = try c.decode([DateDTO].self, forKey: .importantDates)
        }
    }

    struct GiftDTO: Codable {
        var title: String
        var notes: String
        var priceRange: String
        var occasion: String
        var status: String
        /// Optional so pre-capture exports (v1/v2) still decode.
        var sourceCaptureUUID: UUID?
    }

    struct ReminderDTO: Codable {
        var title: String
        var dueDate: Date
        var type: String
        var completed: Bool
        var notes: String
        var sourceCaptureUUID: UUID?
    }

    struct DateDTO: Codable {
        var title: String
        var date: Date
        var repeatsYearly: Bool
        var notes: String
        var sourceCaptureUUID: UUID?
    }

    struct InteractionDTO: Codable {
        /// Stable identity so a `MemoryFact.sourceInteractionUUID` keeps
        /// pointing at the right interaction across export/restore. `nil`
        /// only when decoding a pre-`Interaction.uuid` export.
        var uuid: UUID?
        var type: String
        var date: Date
        var location: String
        var note: String
        var topics: [String]
        var quality: Int
        var followUpNeeded: Bool
        var peopleNames: [String]
        var followUpDate: Date?
        var nextMove: String
        var messageSummary: String
        var isImported: Bool
        var platform: String?
        var rawImportText: String
        var sourceCaptureUUID: UUID?

        init(
            uuid: UUID? = nil, type: String, date: Date, location: String, note: String, topics: [String],
            quality: Int, followUpNeeded: Bool, peopleNames: [String],
            followUpDate: Date? = nil, nextMove: String = "", messageSummary: String = "",
            isImported: Bool = false, platform: String? = nil, rawImportText: String = "",
            sourceCaptureUUID: UUID? = nil
        ) {
            self.uuid = uuid
            self.type = type
            self.date = date
            self.location = location
            self.note = note
            self.topics = topics
            self.quality = quality
            self.followUpNeeded = followUpNeeded
            self.peopleNames = peopleNames
            self.followUpDate = followUpDate
            self.nextMove = nextMove
            self.messageSummary = messageSummary
            self.isImported = isImported
            self.platform = platform
            self.rawImportText = rawImportText
            self.sourceCaptureUUID = sourceCaptureUUID
        }

        private enum CodingKeys: String, CodingKey {
            case uuid, type, date, location, note, topics, quality, followUpNeeded, peopleNames
            case followUpDate, nextMove, messageSummary, isImported, platform, rawImportText
            case sourceCaptureUUID
        }

        /// The original fields are required (every export ever written has
        /// them); the fields added alongside this backup system default
        /// gracefully so an older export still decodes in full.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = (try? c.decodeIfPresent(UUID.self, forKey: .uuid)) ?? nil
            type = try c.decode(String.self, forKey: .type)
            date = try c.decode(Date.self, forKey: .date)
            location = try c.decode(String.self, forKey: .location)
            note = try c.decode(String.self, forKey: .note)
            topics = try c.decode([String].self, forKey: .topics)
            quality = try c.decode(Int.self, forKey: .quality)
            followUpNeeded = try c.decode(Bool.self, forKey: .followUpNeeded)
            peopleNames = try c.decode([String].self, forKey: .peopleNames)
            followUpDate = (try? c.decodeIfPresent(Date.self, forKey: .followUpDate)) ?? nil
            nextMove = decodeOrDefault(c, .nextMove, "")
            messageSummary = decodeOrDefault(c, .messageSummary, "")
            isImported = decodeOrDefault(c, .isImported, false)
            platform = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? nil
            rawImportText = decodeOrDefault(c, .rawImportText, "")
            sourceCaptureUUID = (try? c.decodeIfPresent(UUID.self, forKey: .sourceCaptureUUID)) ?? nil
        }
    }

    struct EventDTO: Codable {
        var name: String
        var date: Date
        var location: String
        var purpose: String
        var notes: String
        var eventKind: String
        var importance: String
        var socialIntensity: String
        var prepNeeded: Bool
        var attendeeNames: [String]
    }

    // MARK: Export

    static func exportData(context: ModelContext) throws -> Data {
        let people = try context.fetch(FetchDescriptor<Person>())
        let interactions = try context.fetch(FetchDescriptor<Interaction>())
        let events = try context.fetch(FetchDescriptor<Event>())
        let captures = try context.fetch(FetchDescriptor<CapturedMemory>())
        let facts = try context.fetch(FetchDescriptor<MemoryFact>())

        var archive = Archive()
        archive.people = people.map { p in
            PersonDTO(
                uuid: p.uuid, name: p.name, nickname: p.nickname, relationshipToMe: p.relationshipToMe,
                category: p.categoryRaw, closeness: p.closeness, priority: p.priority,
                birthday: p.birthday, lastContactedAt: p.lastContactedAt, lastMetAt: p.lastMetAt,
                lastMessagedAt: p.lastMessagedAt, lastCalledAt: p.lastCalledAt,
                isArchived: p.isArchived, checkInCadenceDays: p.checkInCadenceDays,
                notes: p.notes, personalityNotes: p.personalityNotes,
                interests: p.interests, dislikes: p.dislikes, familyMembers: p.familyMembers,
                schoolOrWork: p.schoolOrWork, location: p.location,
                contactMethods: p.contactMethods, tags: p.tags, avatarData: p.avatarData,
                giftIdeas: p.giftIdeas.map { GiftDTO(title: $0.title, notes: $0.notes, priceRange: $0.priceRange, occasion: $0.occasion, status: $0.statusRaw, sourceCaptureUUID: $0.sourceCaptureUUID) },
                reminders: p.reminders.map { ReminderDTO(title: $0.title, dueDate: $0.dueDate, type: $0.typeRaw, completed: $0.completed, notes: $0.notes, sourceCaptureUUID: $0.sourceCaptureUUID) },
                importantDates: p.importantDates.map { DateDTO(title: $0.title, date: $0.date, repeatsYearly: $0.repeatsYearly, notes: $0.notes, sourceCaptureUUID: $0.sourceCaptureUUID) }
            )
        }
        archive.interactions = interactions.map { i in
            InteractionDTO(
                uuid: i.uuid,
                type: i.typeRaw, date: i.date, location: i.location, note: i.note,
                topics: i.topics, quality: i.quality, followUpNeeded: i.followUpNeeded,
                peopleNames: i.people.map(\.name),
                followUpDate: i.followUpDate, nextMove: i.nextMove, messageSummary: i.messageSummary,
                isImported: i.isImported, platform: i.platformRaw.isEmpty ? nil : i.platformRaw,
                rawImportText: i.rawImportText, sourceCaptureUUID: i.sourceCaptureUUID
            )
        }
        archive.events = events.map { e in
            EventDTO(
                name: e.name, date: e.date, location: e.location, purpose: e.purpose, notes: e.notes,
                eventKind: e.eventKindRaw, importance: e.importanceRaw, socialIntensity: e.socialIntensityRaw,
                prepNeeded: e.prepNeeded, attendeeNames: e.attendees.map(\.name)
            )
        }
        archive.captures = captures.map { c in
            CaptureDTO(
                uuid: c.uuid, rawText: c.rawText, transcript: c.transcript, ocrText: c.ocrText,
                source: c.sourceRaw, capturedAt: c.capturedAt,
                trustedPersonIDs: c.trustedPersonIDs, trustedPersonNames: c.trustedPersonNames,
                resolvedPersonIDs: c.resolvedPersonIDs, resolvedPersonNames: c.resolvedPersonNames,
                candidatePersonIDs: c.candidatePersonIDs, candidatePersonNames: c.candidatePersonNames,
                eventName: c.eventName, eventDate: c.eventDate, eventLocation: c.eventLocation,
                typeHint: c.typeHintRaw, status: c.statusRaw, attempts: c.attempts,
                errorMessage: c.errorMessage, inferenceConfidence: c.inferenceConfidence,
                usedLocalFallback: c.usedLocalFallback, title: c.title, detail: c.detail,
                createdAt: c.createdAt
            )
        }
        archive.memoryFacts = facts.map { f in
            FactDTO(
                type: f.typeRaw, value: f.value, dateValue: f.dateValue,
                confidence: f.confidence, status: f.statusRaw, origin: f.originRaw,
                personUUID: f.person?.uuid, personName: f.person?.name,
                sourceCaptureUUID: f.sourceCaptureUUID, sourceInteractionUUID: f.sourceInteractionUUID,
                createdAt: f.createdAt, rejectedAt: f.rejectedAt
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    static func writeExportFile(context: ModelContext) throws -> URL {
        let data = try exportData(context: context)
        let name = "SocialClimber-\(Date.now.formatted(.iso8601.year().month().day())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// The total record count a raw archive file contains, without
    /// touching the live database. Used to refuse restoring an empty or
    /// unreadable backup instead of silently "succeeding" at doing nothing.
    static func recordCount(in data: Data) -> Int? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data) else { return nil }
        return archive.people.count + archive.interactions.count + archive.events.count
            + archive.captures.count + archive.memoryFacts.count
    }

    // MARK: Import

    @discardableResult
    static func importData(_ data: Data, context: ModelContext) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: data)

        let existing = try context.fetch(FetchDescriptor<Person>())
        var byName: [String: Person] = Dictionary(uniqueKeysWithValues: existing.map { ($0.name.lowercased(), $0) })
        var imported = 0

        for dto in archive.people {
            let key = dto.name.lowercased()
            let person: Person
            if let found = byName[key] {
                // An existing local person's `uuid` is never overwritten by
                // an imported value — captures/facts already on this device
                // point at it, and clobbering it would silently break that
                // provenance.
                person = found
            } else {
                person = Person(name: dto.name)
                // Only a brand-new person adopts the imported uuid (falling
                // back to a fresh one for a pre-`Person.uuid` export), so a
                // capture/fact imported from the very same file keeps
                // resolving to this same person afterward.
                person.uuid = dto.uuid ?? UUID()
                context.insert(person)
                byName[key] = person
                imported += 1
            }
            person.nickname = dto.nickname
            person.relationshipToMe = dto.relationshipToMe
            person.categoryRaw = dto.category
            person.closeness = dto.closeness
            person.priority = dto.priority
            person.birthday = dto.birthday
            person.lastContactedAt = dto.lastContactedAt
            person.lastMetAt = dto.lastMetAt
            person.lastMessagedAt = dto.lastMessagedAt
            person.lastCalledAt = dto.lastCalledAt
            person.isArchived = dto.isArchived
            person.checkInCadenceDays = dto.checkInCadenceDays
            person.notes = dto.notes
            person.personalityNotes = dto.personalityNotes
            person.interests = dto.interests
            person.dislikes = dto.dislikes
            person.familyMembers = dto.familyMembers
            person.schoolOrWork = dto.schoolOrWork
            person.location = dto.location
            person.contactMethods = dto.contactMethods
            person.tags = dto.tags
            if let avatar = dto.avatarData { person.avatarData = avatar }

            // Replace child collections wholesale to avoid duplicates.
            person.giftIdeas.forEach { context.delete($0) }
            person.reminders.forEach {
                NotificationService.shared.cancel(reminder: $0)
                context.delete($0)
            }
            person.importantDates.forEach {
                NotificationService.shared.cancel(importantDate: $0)
                context.delete($0)
            }
            for gift in dto.giftIdeas {
                let record = GiftIdea(title: gift.title, person: person, notes: gift.notes, priceRange: gift.priceRange, occasion: gift.occasion, status: GiftStatus(rawValue: gift.status) ?? .idea)
                record.sourceCaptureUUID = gift.sourceCaptureUUID
                context.insert(record)
            }
            for reminder in dto.reminders {
                let record = Reminder(title: reminder.title, dueDate: reminder.dueDate, type: ReminderType(rawValue: reminder.type) ?? .custom, person: person, notes: reminder.notes)
                record.completed = reminder.completed
                record.sourceCaptureUUID = reminder.sourceCaptureUUID
                context.insert(record)
                NotificationService.shared.schedule(reminder: record)
            }
            for date in dto.importantDates {
                let record = ImportantDate(title: date.title, date: date.date, repeatsYearly: date.repeatsYearly, person: person, notes: date.notes)
                record.sourceCaptureUUID = date.sourceCaptureUUID
                context.insert(record)
                NotificationService.shared.schedule(importantDate: record)
            }
            NotificationService.shared.scheduleBirthday(for: person)
        }

        // Interactions: skip exact duplicates (same date + note).
        let existingInteractions = try context.fetch(FetchDescriptor<Interaction>())
        let seenInteractions = Set(existingInteractions.map { "\($0.date.timeIntervalSince1970)|\($0.note)" })
        for dto in archive.interactions {
            guard !seenInteractions.contains("\(dto.date.timeIntervalSince1970)|\(dto.note)") else { continue }
            let interaction = Interaction(
                type: InteractionType(rawValue: dto.type) ?? .other,
                date: dto.date, location: dto.location, note: dto.note,
                topics: dto.topics, quality: dto.quality, followUpNeeded: dto.followUpNeeded,
                followUpDate: dto.followUpDate, nextMove: dto.nextMove, messageSummary: dto.messageSummary
            )
            interaction.isImported = dto.isImported
            interaction.platformRaw = dto.platform ?? ""
            interaction.rawImportText = dto.rawImportText
            interaction.sourceCaptureUUID = dto.sourceCaptureUUID
            if let uuid = dto.uuid { interaction.uuid = uuid }
            interaction.people = dto.peopleNames.compactMap { byName[$0.lowercased()] }
            context.insert(interaction)
        }

        // Events: skip exact duplicates (same date + name); nothing to
        // update in place since, unlike people, events have no stable
        // identity beyond that pair.
        let existingEvents = try context.fetch(FetchDescriptor<Event>())
        let seenEvents = Set(existingEvents.map { "\($0.date.timeIntervalSince1970)|\($0.name.lowercased())" })
        for dto in archive.events {
            guard !seenEvents.contains("\(dto.date.timeIntervalSince1970)|\(dto.name.lowercased())") else { continue }
            let event = Event(
                name: dto.name, date: dto.date, location: dto.location, purpose: dto.purpose, notes: dto.notes,
                attendees: dto.attendeeNames.compactMap { byName[$0.lowercased()] },
                eventKind: EventKind(rawValue: dto.eventKind) ?? .hangout,
                importance: ImportanceLevel(rawValue: dto.importance) ?? .medium,
                socialIntensity: ImportanceLevel(rawValue: dto.socialIntensity) ?? .medium,
                prepNeeded: dto.prepNeeded
            )
            context.insert(event)
        }

        // Captures: skip duplicates by their stable UUID; restoring can
        // therefore never re-run or double-import a capture.
        let existingCaptures = try context.fetch(FetchDescriptor<CapturedMemory>())
        let seenCaptureUUIDs = Set(existingCaptures.map(\.uuid))
        for dto in archive.captures {
            guard !seenCaptureUUIDs.contains(dto.uuid) else { continue }
            let capture = CapturedMemory(
                rawText: dto.rawText,
                source: CaptureSource(rawValue: dto.source) ?? .text,
                transcript: dto.transcript,
                capturedAt: dto.capturedAt,
                trustedPersonIDs: dto.trustedPersonIDs,
                trustedPersonNames: dto.trustedPersonNames,
                eventName: dto.eventName,
                eventDate: dto.eventDate,
                eventLocation: dto.eventLocation,
                typeHint: dto.typeHint.isEmpty ? nil : InteractionType(rawValue: dto.typeHint)
            )
            capture.uuid = dto.uuid
            capture.ocrText = dto.ocrText
            capture.resolvedPersonIDs = dto.resolvedPersonIDs
            capture.resolvedPersonNames = dto.resolvedPersonNames
            capture.candidatePersonIDs = dto.candidatePersonIDs
            capture.candidatePersonNames = dto.candidatePersonNames
            // Restored captures whose processing was mid-flight resume as
            // queued; processed/dismissed ones stay exactly as they were —
            // their created records restore separately, so re-processing
            // them would duplicate data.
            let status = CaptureStatus(rawValue: dto.status) ?? .queued
            capture.statusRaw = (status == .processing ? CaptureStatus.queued : status).rawValue
            capture.attempts = dto.attempts
            capture.errorMessage = dto.errorMessage
            capture.inferenceConfidence = dto.inferenceConfidence
            capture.usedLocalFallback = dto.usedLocalFallback
            capture.title = dto.title
            capture.detail = dto.detail
            capture.createdAt = dto.createdAt
            context.insert(capture)
        }

        // Memory facts: scoped to their source capture where one exists —
        // far more precise than name+type+value, and correctly handles an
        // unattributed fact (no person) instead of colliding every
        // unattributed fact of the same type/value together.
        let byUUID: [UUID: Person] = Dictionary(uniqueKeysWithValues: byName.values.map { ($0.uuid, $0) })
        let existingFacts = try context.fetch(FetchDescriptor<MemoryFact>())
        func factKey(sourceCaptureUUID: UUID?, personName: String?, type: String, value: String) -> String {
            if let sourceCaptureUUID {
                return "\(sourceCaptureUUID.uuidString)|\(type)|\(value.lowercased())"
            }
            return "legacy|\((personName ?? "").lowercased())|\(type)|\(value.lowercased())"
        }
        let seenFacts = Set(existingFacts.map {
            factKey(sourceCaptureUUID: $0.sourceCaptureUUID, personName: $0.person?.name, type: $0.typeRaw, value: $0.value)
        })
        for dto in archive.memoryFacts {
            let key = factKey(sourceCaptureUUID: dto.sourceCaptureUUID, personName: dto.personName, type: dto.type, value: dto.value)
            guard !seenFacts.contains(key) else { continue }
            // IDs are authoritative; the cached name is only a fallback for
            // a fact exported before `personUUID` existed.
            let person = dto.personUUID.flatMap { byUUID[$0] } ?? dto.personName.flatMap { byName[$0.lowercased()] }
            let fact = MemoryFact(
                type: MemoryFactType(rawValue: dto.type) ?? .general,
                value: dto.value,
                person: person,
                confidence: dto.confidence,
                status: MemoryFactStatus(rawValue: dto.status) ?? .suggested,
                dateValue: dto.dateValue,
                sourceCaptureUUID: dto.sourceCaptureUUID,
                sourceInteractionUUID: dto.sourceInteractionUUID,
                origin: MemoryFactOrigin(rawValue: dto.origin) ?? .machine
            )
            fact.createdAt = dto.createdAt
            fact.rejectedAt = dto.rejectedAt
            context.insert(fact)
        }

        try context.save()
        return imported
    }
}
