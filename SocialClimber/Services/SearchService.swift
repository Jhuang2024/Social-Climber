import Foundation

/// Local search across all data, with light natural-language handling for
/// queries like "who likes F1?", "who did I talk to about internships?",
/// or "birthdays in November?".
enum SearchService {

    struct PersonHit: Identifiable {
        let person: Person
        let reason: String
        var id: ObjectIdentifier { ObjectIdentifier(person) }
    }

    struct InteractionHit: Identifiable {
        let interaction: Interaction
        let reason: String
        var id: ObjectIdentifier { ObjectIdentifier(interaction) }
    }

    struct GiftHit: Identifiable {
        let gift: GiftIdea
        var id: ObjectIdentifier { ObjectIdentifier(gift) }
    }

    struct DateHit: Identifiable {
        let title: String
        let date: Date
        let person: Person?
        let id = UUID()
    }

    struct Results {
        var people: [PersonHit] = []
        var interactions: [InteractionHit] = []
        var gifts: [GiftHit] = []
        var dates: [DateHit] = []
        var isEmpty: Bool { people.isEmpty && interactions.isEmpty && gifts.isEmpty && dates.isEmpty }
    }

    private static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
    ]

    static func search(
        _ rawQuery: String,
        people: [Person],
        interactions: [Interaction],
        gifts: [GiftIdea],
        dates: [ImportantDate]
    ) -> Results {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
            .lowercased()
        guard query.count >= 2 else { return Results() }

        var results = Results()

        // "birthdays in november" / "november birthdays"
        if query.contains("birthday") {
            let month = months.first { query.contains($0.key) }?.value
            for person in people {
                guard let birthday = person.birthday else { continue }
                let bMonth = Calendar.current.component(.month, from: birthday)
                if month == nil || bMonth == month {
                    results.dates.append(DateHit(title: "\(person.firstName)'s birthday", date: birthday.nextYearlyOccurrence, person: person))
                }
            }
            if month != nil {
                results.dates.sort { Calendar.current.component(.day, from: $0.date) < Calendar.current.component(.day, from: $1.date) }
                return results
            }
        }

        // "who likes X" / "who is into X" / "who enjoys X"
        if let subject = subject(of: query, markers: ["who likes ", "who is into ", "who enjoys ", "who loves ", "who's into "]) {
            for person in people where matches(person.combinedInterests, subject) {
                results.people.append(PersonHit(person: person, reason: "Likes \(matchedTerm(person.combinedInterests, subject) ?? subject)"))
            }
            if !results.people.isEmpty { return results }
        }

        // "who did i talk to about X" / "talked about X"
        if let subject = subject(of: query, markers: ["talk to about ", "talked about ", "talk about ", "discussed ", "conversation about "]) {
            for interaction in interactions {
                if matches(interaction.topics, subject) || interaction.note.lowercased().contains(subject) {
                    results.interactions.append(InteractionHit(interaction: interaction, reason: "Talked about \(subject)"))
                    for person in interaction.people where !results.people.contains(where: { $0.person === person }) {
                        results.people.append(PersonHit(person: person, reason: "Talked about \(subject)"))
                    }
                }
            }
            if !results.interactions.isEmpty { return results }
        }

        // General substring search.
        let term = query
        for person in people {
            var reason: String?
            if person.name.lowercased().contains(term) || person.nickname.lowercased().contains(term) {
                reason = person.relationshipToMe.isEmpty ? person.category.label : person.relationshipToMe
            } else if person.relationshipToMe.lowercased().contains(term) {
                reason = person.relationshipToMe
            } else if let match = matchedTerm(person.combinedInterests, term) {
                reason = "Likes \(match)"
            } else if let match = matchedTerm(person.combinedDislikes, term) {
                reason = "Dislikes \(match)"
            } else if let match = matchedTerm(person.tags, term) {
                reason = "Tagged \(match)"
            } else if person.notes.lowercased().contains(term) || person.personalityNotes.lowercased().contains(term) {
                reason = "Mentioned in notes"
            } else if person.schoolOrWork.lowercased().contains(term) {
                reason = person.schoolOrWork
            } else if person.location.lowercased().contains(term) {
                reason = person.location
            } else if let fact = person.visibleFacts.first(where: { $0.value.lowercased().contains(term) }) {
                reason = fact.value
            }
            if let reason {
                results.people.append(PersonHit(person: person, reason: reason))
            }
        }
        for interaction in interactions {
            if interaction.note.lowercased().contains(term) || matches(interaction.topics, term) || interaction.location.lowercased().contains(term) {
                results.interactions.append(InteractionHit(interaction: interaction, reason: interaction.peopleNames))
            }
        }
        for gift in gifts {
            if gift.title.lowercased().contains(term) || gift.notes.lowercased().contains(term) || gift.occasion.lowercased().contains(term) {
                results.gifts.append(GiftHit(gift: gift))
            }
        }
        for date in dates {
            if date.title.lowercased().contains(term), let next = date.nextOccurrence {
                results.dates.append(DateHit(title: date.title, date: next, person: date.person))
            }
        }

        results.interactions.sort { $0.interaction.date > $1.interaction.date }
        return results
    }

    private static func subject(of query: String, markers: [String]) -> String? {
        for marker in markers {
            if let range = query.range(of: marker) {
                let subject = String(query[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !subject.isEmpty { return subject }
            }
        }
        return nil
    }

    private static func matches(_ list: [String], _ term: String) -> Bool {
        matchedTerm(list, term) != nil
    }

    private static func matchedTerm(_ list: [String], _ term: String) -> String? {
        list.first { $0.lowercased().contains(term) || term.contains($0.lowercased()) }
    }
}
