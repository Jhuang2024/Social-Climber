import Foundation
import SwiftData

@Model
final class GiftIdea {
    var title: String = ""
    var notes: String = ""
    var priceRange: String = ""
    var occasion: String = ""
    var statusRaw: String = GiftStatus.idea.rawValue
    /// UUID of the `CapturedMemory` that automatically created this gift
    /// idea, if any (see `Interaction.sourceCaptureUUID`).
    var sourceCaptureUUID: UUID?
    var createdAt: Date = Date()

    var person: Person?

    init(
        title: String,
        person: Person? = nil,
        notes: String = "",
        priceRange: String = "",
        occasion: String = "",
        status: GiftStatus = .idea
    ) {
        self.title = title
        self.person = person
        self.notes = notes
        self.priceRange = priceRange
        self.occasion = occasion
        self.statusRaw = status.rawValue
        self.createdAt = .now
    }

    var status: GiftStatus {
        get { GiftStatus(rawValue: statusRaw) ?? .idea }
        set { statusRaw = newValue.rawValue }
    }
}
