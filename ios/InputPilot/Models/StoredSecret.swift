import Foundation
import SwiftData

@Model final class StoredSecret {
    var id: UUID
    @Attribute(.unique) var name: String
    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(name: String, note: String = "") {
        id = UUID()
        self.name = name
        self.note = note
        createdAt = Date()
        updatedAt = Date()
    }
}
