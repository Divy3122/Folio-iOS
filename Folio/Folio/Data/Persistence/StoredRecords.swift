import Foundation
import SwiftData

// Versioned payloads keep framework types out of domain contracts.
@Model final class StoredReceipt {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var schemaVersion: Int = 1
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model final class StoredReminder {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var schemaVersion: Int = 1
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}
