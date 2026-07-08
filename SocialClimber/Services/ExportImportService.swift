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
        var version = 2
        var exportedAt = Date()
        var people: [PersonDTO] = []
        var interactions: [InteractionDTO] = []
        var events: [EventDTO] = []

        init() {}

        private enum CodingKeys: String, CodingKey {
            case version, exportedAt, people, interactions, events
        }

        /// Every field decoded with a fallback to its default, so an older
        /// export (from before `events` existed) still restores everything
        /// it originally had, instead of failing the whole file over one
        /// missing key.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = decodeOrDefault(c, .version, 1)
            exportedAt = decodeOrDefault(c, .exportedAt, Date())
            people = decodeOrDefault(c, .people, [])
            interactions = decodeOrDefault(c, .interactions, [])
            events = decodeOrDefault(c, .events, [])
        }
    }

    struct PersonDTO: Codable {
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
    }

    struct GiftDTO: Codable {
        var title: String
        var notes: String
        var priceRange: String
        var occasion: String
        var status: String
    }

    struct ReminderDTO: Codable {
        var title: String
        var dueDate: Date
        var type: String
        var completed: Bool
        var notes: String
    }

    struct DateDTO: Codable {
        var title: String
        var date: Date
        var repeatsYearly: Bool
        var notes: String
    }

    struct InteractionDTO: Codable {
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

        init(
            type: String, date: Date, location: String, note: String, topics: [String],
            quality: Int, followUpNeeded: Bool, peopleNames: [String],
            followUpDate: Date? = nil, nextMove: String = "", messageSummary: String = "",
            isImported: Bool = false, platform: String? = nil, rawImportText: String = ""
        ) {
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
        }

        private enum CodingKeys: String, CodingKey {
            case type, date, location, note, topics, quality, followUpNeeded, peopleNames
            case followUpDate, nextMove, messageSummary, isImported, platform, rawImportText
        }

        /// The original fields are required (every export ever written has
        /// them); the fields added alongside this backup system default
        /// gracefully so an older export still decodes in full.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
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

        var archive = Archive()
        archive.people = people.map { p in
            PersonDTO(
                name: p.name, nickname: p.nickname, relationshipToMe: p.relationshipToMe,
                category: p.categoryRaw, closeness: p.closeness, priority: p.priority,
                birthday: p.birthday, lastContactedAt: p.lastContactedAt, lastMetAt: p.lastMetAt,
                lastMessagedAt: p.lastMessagedAt, lastCalledAt: p.lastCalledAt,
                isArchived: p.isArchived, checkInCadenceDays: p.checkInCadenceDays,
                notes: p.notes, personalityNotes: p.personalityNotes,
                interests: p.interests, dislikes: p.dislikes, familyMembers: p.familyMembers,
                schoolOrWork: p.schoolOrWork, location: p.location,
                contactMethods: p.contactMethods, tags: p.tags, avatarData: p.avatarData,
                giftIdeas: p.giftIdeas.map { GiftDTO(title: $0.title, notes: $0.notes, priceRange: $0.priceRange, occasion: $0.occasion, status: $0.statusRaw) },
                reminders: p.reminders.map { ReminderDTO(title: $0.title, dueDate: $0.dueDate, type: $0.typeRaw, completed: $0.completed, notes: $0.notes) },
                importantDates: p.importantDates.map { DateDTO(title: $0.title, date: $0.date, repeatsYearly: $0.repeatsYearly, notes: $0.notes) }
            )
        }
        archive.interactions = interactions.map { i in
            InteractionDTO(
                type: i.typeRaw, date: i.date, location: i.location, note: i.note,
                topics: i.topics, quality: i.quality, followUpNeeded: i.followUpNeeded,
                peopleNames: i.people.map(\.name),
                followUpDate: i.followUpDate, nextMove: i.nextMove, messageSummary: i.messageSummary,
                isImported: i.isImported, platform: i.platformRaw.isEmpty ? nil : i.platformRaw,
                rawImportText: i.rawImportText
            )
        }
        archive.events = events.map { e in
            EventDTO(
                name: e.name, date: e.date, location: e.location, purpose: e.purpose, notes: e.notes,
                eventKind: e.eventKindRaw, importance: e.importanceRaw, socialIntensity: e.socialIntensityRaw,
                prepNeeded: e.prepNeeded, attendeeNames: e.attendees.map(\.name)
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
                person = found
            } else {
                person = Person(name: dto.name)
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
                context.insert(GiftIdea(title: gift.title, person: person, notes: gift.notes, priceRange: gift.priceRange, occasion: gift.occasion, status: GiftStatus(rawValue: gift.status) ?? .idea))
            }
            for reminder in dto.reminders {
                let record = Reminder(title: reminder.title, dueDate: reminder.dueDate, type: ReminderType(rawValue: reminder.type) ?? .custom, person: person, notes: reminder.notes)
                record.completed = reminder.completed
                context.insert(record)
                NotificationService.shared.schedule(reminder: record)
            }
            for date in dto.importantDates {
                let record = ImportantDate(title: date.title, date: date.date, repeatsYearly: date.repeatsYearly, person: person, notes: date.notes)
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

        try context.save()
        return imported
    }
}
