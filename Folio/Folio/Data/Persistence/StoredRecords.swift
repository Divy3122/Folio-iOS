import Foundation
import SwiftData

// Versioned payloads keep framework types out of domain contracts.
@Model final class StoredReceipt {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var schemaVersion: Int = 1

    // Derived query columns; the payload is the source of truth.
    var retailerName: String = ""
    var purchaseDate: Date = Date.distantPast
    var totalMinorUnits: Int = 0
    var currencyCode: String = ""
    var profileRaw: String = ""
    var category: String = ""
    var searchText: String = ""
    var fingerprint: String = ""
    var indexVersion: Int = 0

    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }

    func apply(_ index: ReceiptIndex) {
        retailerName = index.retailerName
        purchaseDate = index.purchaseDate
        totalMinorUnits = index.totalMinorUnits
        currencyCode = index.currencyCode
        profileRaw = index.profileRaw
        category = index.category
        searchText = index.searchText
        fingerprint = index.fingerprint
        indexVersion = ReceiptIndex.currentVersion
    }
}

@Model final class StoredReminder {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var schemaVersion: Int = 1
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

/// Saved retailers live in their own store file, so the app's main container is not touched.
@Model final class StoredRetailer {
    @Attribute(.unique) var id: UUID
    var name: String = ""
    var nameKey: String = ""
    var payload: Data
    var schemaVersion: Int = 1

    init(id: UUID, name: String, nameKey: String, payload: Data) {
        self.id = id
        self.name = name
        self.nameKey = nameKey
        self.payload = payload
    }
}

struct ReceiptIndex: Sendable {
    static let currentVersion = 2

    let retailerName: String
    let purchaseDate: Date
    let totalMinorUnits: Int
    let currencyCode: String
    let profileRaw: String
    let category: String
    let searchText: String
    let fingerprint: String

    init(_ record: ReceiptRecord) {
        let receipt = record.receipt
        retailerName = receipt.retailer.name
        purchaseDate = receipt.purchasedAt
        totalMinorUnits = ReceiptFingerprint.minorUnits(receipt.total)
        currencyCode = receipt.currencyCode
        profileRaw = receipt.profile.rawValue
        category = record.metadata.category

        let words = [receipt.retailer.name, record.metadata.category, record.metadata.notes]
            + record.metadata.tags
            + record.metadata.policies.flatMap { [$0.kind.rawValue, $0.title] }
            + receipt.items.map(\.name)
            + (record.costs?.products.map(\.name) ?? [])
        searchText = words.joined(separator: " ").lowercased()

        fingerprint = ReceiptFingerprint.make(for: receipt)
    }
}

/// Version 1 is a bare PurchaseReceipt (original build); version 2 is a ReceiptRecord.
enum ReceiptPayloadCodec {
    static let currentVersion = 2

    static func encode(_ record: ReceiptRecord) throws -> Data {
        try JSONEncoder().encode(record)
    }

    static func decode(_ data: Data, schemaVersion: Int) throws -> ReceiptRecord {
        switch schemaVersion {
        case 1:
            let receipt = try JSONDecoder().decode(PurchaseReceipt.self, from: data)
            var record = ReceiptRecord(receipt: receipt)
            record.metadata.createdAt = receipt.purchasedAt
            record.metadata.updatedAt = receipt.purchasedAt
            return record
        case 2:
            return try JSONDecoder().decode(ReceiptRecord.self, from: data)
        default:
            throw FolioError.persistenceFailure
        }
    }
}
