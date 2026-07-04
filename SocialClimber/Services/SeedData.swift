import Foundation
import SwiftData

/// Realistic sample data inserted on first launch so the app is usable
/// immediately. Can be wiped from Settings.
enum SeedData {

    static func seedIfNeeded(context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didSeed") else { return }
        let count = (try? context.fetchCount(FetchDescriptor<Person>())) ?? 0
        guard count == 0 else {
            defaults.set(true, forKey: "didSeed")
            return
        }
        seed(context: context)
        defaults.set(true, forKey: "didSeed")
    }

    static func seed(context: ModelContext) {
        let cal = Calendar.current
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: .now)! }
        func daysAhead(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: .now)! }
        func birthday(month: Int, day: Int, year: Int = 2003) -> Date {
            cal.date(from: DateComponents(year: year, month: month, day: day))!
        }

        // 1. Family member
        let mom = Person(name: "Linda Huang", nickname: "Mom", relationshipToMe: "My mom", category: .family, closeness: 5, priority: 5, birthday: birthday(month: 11, day: 8, year: 1970))
        mom.interests = ["Gardening", "Cooking shows", "Morning walks", "Tea"]
        mom.dislikes = ["Being sent voicemails", "Cold weather"]
        mom.familyMembers = ["Dad (Wei)", "Me"]
        mom.location = "San Jose, CA"
        mom.personalityNotes = "Worries when I don't call for a week. Loves hearing small everyday details more than big news."
        mom.notes = "Call every Sunday evening. Wants to redo the backyard garden this year."
        mom.contactMethods = [ContactMethod(label: "Phone", value: "(408) 555-0132")]
        mom.tags = ["family", "call weekly"]
        mom.lastContactedAt = daysAgo(2)
        mom.lastCalledAt = daysAgo(2)
        mom.checkInCadenceDays = 7

        // 2. Close friend
        let alex = Person(name: "Alex Rivera", nickname: "Alex", relationshipToMe: "Best friend since high school", category: .closeFriend, closeness: 5, priority: 5, birthday: birthday(month: 3, day: 22))
        alex.interests = ["Formula 1", "Sim racing", "Ramen spots", "Photography"]
        alex.dislikes = ["Flaky plans", "Small talk"]
        alex.schoolOrWork = "SJSU, mechanical engineering"
        alex.location = "San Jose, CA"
        alex.personalityNotes = "Dry humor, opens up one-on-one. Gets quiet when stressed about school — worth asking directly."
        alex.notes = "Planning a Laguna Seca trip together this summer. He's saving for a sim rig."
        alex.tags = ["high school", "f1"]
        alex.lastContactedAt = daysAgo(5)
        alex.lastMetAt = daysAgo(12)
        alex.lastMessagedAt = daysAgo(5)

        // 3. Berkeley roommate
        let dev = Person(name: "Dev Patel", relationshipToMe: "Berkeley roommate", category: .roommate, closeness: 4, priority: 4, birthday: birthday(month: 7, day: 14))
        dev.interests = ["Basketball", "Cooking", "Valorant", "Hiking"]
        dev.dislikes = ["Dishes left in the sink"]
        dev.schoolOrWork = "UC Berkeley, CS"
        dev.location = "Berkeley, CA"
        dev.familyMembers = ["Sister (Priya)"]
        dev.personalityNotes = "Extroverted, organizes most apartment events. Competitive about everything, including cooking."
        dev.notes = "Splitting groceries via Splitwise. Talking about a Tahoe cabin trip with the apartment in December."
        dev.tags = ["berkeley", "apartment"]
        dev.lastContactedAt = daysAgo(1)
        dev.lastMetAt = daysAgo(1)

        // 4. UCC classmate
        let maya = Person(name: "Maya Chen", relationshipToMe: "UCC classmate from stats", category: .classmate, closeness: 3, priority: 3, birthday: birthday(month: 11, day: 27))
        maya.interests = ["K-dramas", "Boba", "Data science", "Badminton"]
        maya.schoolOrWork = "UCC, statistics"
        maya.location = "Dublin, Ireland"
        maya.personalityNotes = "Quietly funny once comfortable. Great study partner — very organized."
        maya.notes = "Study group for the stats final. She's applying for data science internships for next summer."
        maya.tags = ["ucc", "study group"]
        maya.lastContactedAt = daysAgo(9)
        maya.lastMessagedAt = daysAgo(9)

        // 5. Mentor
        let sarah = Person(name: "Sarah Kim", relationshipToMe: "Mentor from research lab", category: .mentor, closeness: 3, priority: 5, birthday: birthday(month: 5, day: 3, year: 1988))
        sarah.interests = ["Trail running", "Espresso", "ML research", "Sci-fi novels"]
        sarah.schoolOrWork = "PhD researcher, Berkeley AI lab"
        sarah.location = "Oakland, CA"
        sarah.personalityNotes = "Direct but generous with time. Prefers concise emails with specific questions."
        sarah.notes = "Meet roughly monthly for coffee. She offered to review my grad school statement in the fall."
        sarah.tags = ["mentor", "research"]
        sarah.lastContactedAt = daysAgo(26)
        sarah.lastMetAt = daysAgo(26)
        sarah.checkInCadenceDays = 30

        // 6. Acquaintance
        let jordan = Person(name: "Jordan Lee", relationshipToMe: "Friend of a friend from climbing gym", category: .acquaintance, closeness: 2, priority: 2)
        jordan.interests = ["Bouldering", "Vinyl records", "Coffee brewing"]
        jordan.schoolOrWork = "Works at a startup in SF"
        jordan.location = "San Francisco, CA"
        jordan.personalityNotes = "Easygoing, always down for a climbing session."
        jordan.notes = "Met through Dev at Berkeley Ironworks. Mentioned a good record store in Oakland."
        jordan.tags = ["climbing"]
        jordan.lastContactedAt = daysAgo(48)
        jordan.lastMetAt = daysAgo(48)

        // 7. Professional contact
        let priya = Person(name: "Priya Sharma", relationshipToMe: "Recruiter from career fair", category: .professional, closeness: 1, priority: 4)
        priya.interests = ["Hiring for SWE internships"]
        priya.schoolOrWork = "University recruiter, Stripe"
        priya.location = "SF Bay Area"
        priya.contactMethods = [ContactMethod(label: "Email", value: "priya@example.com"), ContactMethod(label: "LinkedIn", value: "linkedin.com/in/priyasharma")]
        priya.personalityNotes = "Responsive, friendly. Said to reach out again when summer applications open."
        priya.notes = "Met at the fall career fair. Follow up in August about internship timeline."
        priya.tags = ["recruiting", "internship"]
        priya.lastContactedAt = daysAgo(80)
        priya.lastMessagedAt = daysAgo(80)

        let people = [mom, alex, dev, maya, sarah, jordan, priya]
        people.forEach { context.insert($0) }

        // Interactions
        let i1 = Interaction(type: .call, date: daysAgo(2), note: "Sunday call with Mom. Garden planning is in full swing — she wants raised beds. Dad's knee is doing better after PT.", topics: ["Family", "Health"], quality: 4)
        i1.people = [mom]

        let i2 = Interaction(type: .inPerson, date: daysAgo(12), location: "Ippudo, San Jose", note: "Ramen with Alex. He's deep into F1 season predictions and started building a sim racing rig. Stressed about thermo midterm. He would love a Lando Norris cap for his birthday.", topics: ["Sports", "Food", "School"], quality: 5, followUpNeeded: true)
        i2.people = [alex]

        let i3 = Interaction(type: .inPerson, date: daysAgo(1), location: "Apartment", note: "Cooked dinner with Dev, planned the December Tahoe cabin trip. He's trying to convince everyone to do a ski lesson day.", topics: ["Food", "Travel"], quality: 4)
        i3.people = [dev]

        let i4 = Interaction(type: .message, date: daysAgo(9), note: "Maya asked about internship applications — she's targeting data science roles and wants to trade resume feedback. Talked about internships and the stats final.", topics: ["Career", "School"], quality: 3, followUpNeeded: true)
        i4.people = [maya]

        let i5 = Interaction(type: .inPerson, date: daysAgo(26), location: "Blue Bottle, Oakland", note: "Monthly coffee with Sarah. Discussed grad school timeline and which labs to look at. She recommended two papers to read before next time.", topics: ["Career", "School"], quality: 5, followUpNeeded: true)
        i5.people = [sarah]

        let i6 = Interaction(type: .inPerson, date: daysAgo(48), location: "Berkeley Ironworks", note: "Climbing session with Jordan and Dev. Jordan finally sent his V5 project. Talked about vinyl and coffee gear.", topics: ["Sports"], quality: 4)
        i6.people = [jordan, dev]

        [i1, i2, i3, i4, i5, i6].forEach { context.insert($0) }

        // Gift ideas
        context.insert(GiftIdea(title: "Lando Norris cap", person: alex, notes: "Mentioned at ramen — check the official F1 store", priceRange: "$30–45", occasion: "Birthday (Mar 22)", status: .idea))
        context.insert(GiftIdea(title: "Raised garden bed kit", person: mom, notes: "For the backyard project", priceRange: "$80–120", occasion: "Mother's Day", status: .planned))
        context.insert(GiftIdea(title: "Nice chef's knife", person: dev, notes: "He keeps borrowing mine", priceRange: "$60–100", occasion: "Birthday (Jul 14)", status: .idea))

        // Reminders
        context.insert(Reminder(title: "Call Mom (Sunday)", dueDate: daysAhead(3), type: .checkIn, person: mom))
        context.insert(Reminder(title: "Ask Alex how the thermo midterm went", dueDate: daysAhead(1), type: .followUp, person: alex))
        context.insert(Reminder(title: "Send Maya my resume for feedback swap", dueDate: daysAhead(2), type: .followUp, person: maya))
        context.insert(Reminder(title: "Read Sarah's two paper recs before next coffee", dueDate: daysAhead(7), type: .followUp, person: sarah))
        context.insert(Reminder(title: "Email Priya about summer internship timeline", dueDate: daysAhead(30), type: .followUp, person: priya))
        context.insert(Reminder(title: "Invite Jordan climbing", dueDate: daysAhead(5), type: .checkIn, person: jordan))

        // Important dates
        context.insert(ImportantDate(title: "Parents' anniversary", date: birthday(month: 9, day: 15, year: 1995), repeatsYearly: true, person: mom))
        context.insert(ImportantDate(title: "Tahoe cabin trip", date: daysAhead(45), repeatsYearly: false, person: dev, notes: "Book the cabin by end of month"))
        context.insert(ImportantDate(title: "Stats final", date: daysAhead(20), repeatsYearly: false, person: maya))

        try? context.save()
    }

    static func clearAll(context: ModelContext) {
        try? context.delete(model: ConversationSummary.self)
        try? context.delete(model: Interaction.self)
        try? context.delete(model: VoiceNote.self)
        try? context.delete(model: GiftIdea.self)
        try? context.delete(model: Reminder.self)
        try? context.delete(model: ImportantDate.self)
        try? context.delete(model: Person.self)
        try? context.save()
        NotificationService.shared.cancelAll()
    }
}
