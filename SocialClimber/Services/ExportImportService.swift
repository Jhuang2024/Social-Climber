import Foundation
import SwiftData

/// JSON export/import of the whole database. People are matched by name on
/// import, so re-importing a backup merges instead of duplicating.
enum ExportImportService {

    // MARK: DTOs

    struct Archive: Codable {
        var version = 1
        var exportedAt = Date()
        var people: [PersonDTO] = []
        var interactions: [InteractionDTO] = []
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
        /// Optional so archives exported before this field existed still decode.
        var instagramUsername: String?
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
    }

    // MARK: Export

    static func exportData(context: ModelContext) throws -> Data {
        let people = try context.fetch(FetchDescriptor<Person>())
        let interactions = try context.fetch(FetchDescriptor<Interaction>())

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
                contactMethods: p.contactMethods, tags: p.tags,
                instagramUsername: p.instagramUsername, avatarData: p.avatarData,
                giftIdeas: p.giftIdeas.map { GiftDTO(title: $0.title, notes: $0.notes, priceRange: $0.priceRange, occasion: $0.occasion, status: $0.statusRaw) },
                reminders: p.reminders.map { ReminderDTO(title: $0.title, dueDate: $0.dueDate, type: $0.typeRaw, completed: $0.completed, notes: $0.notes) },
                importantDates: p.importantDates.map { DateDTO(title: $0.title, date: $0.date, repeatsYearly: $0.repeatsYearly, notes: $0.notes) }
            )
        }
        archive.interactions = interactions.map { i in
            InteractionDTO(
                type: i.typeRaw, date: i.date, location: i.location, note: i.note,
                topics: i.topics, quality: i.quality, followUpNeeded: i.followUpNeeded,
                peopleNames: i.people.map(\.name)
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
            if let username = dto.instagramUsername, !username.isEmpty {
                person.instagramUsername = username
            }
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
        let seen = Set(existingInteractions.map { "\($0.date.timeIntervalSince1970)|\($0.note)" })
        for dto in archive.interactions {
            guard !seen.contains("\(dto.date.timeIntervalSince1970)|\(dto.note)") else { continue }
            let interaction = Interaction(
                type: InteractionType(rawValue: dto.type) ?? .other,
                date: dto.date, location: dto.location, note: dto.note,
                topics: dto.topics, quality: dto.quality, followUpNeeded: dto.followUpNeeded
            )
            interaction.people = dto.peopleNames.compactMap { byName[$0.lowercased()] }
            context.insert(interaction)
        }

        try context.save()
        return imported
    }
}
