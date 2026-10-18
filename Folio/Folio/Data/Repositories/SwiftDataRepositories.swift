import Foundation
import SwiftData

/// Dedicated context: rollback cannot discard another feature's pending changes.
@MainActor final class SwiftDataReceiptRepository: ReceiptRepository, ReceiptLibraryRepository {
    private let context: ModelContext
    private var indexUpToDate = false

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func save(_ receipt: PurchaseReceipt) async throws {
        do {
            var record = try existingRecord(id: receipt.id) ?? ReceiptRecord(receipt: receipt)
            record.receipt = receipt
            record.metadata.updatedAt = Date()
            try upsert(record)
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }

    func fetchAll() async throws -> [PurchaseReceipt] {
        do {
            return try context.fetch(FetchDescriptor<StoredReceipt>()).map { try decode($0).receipt }
        } catch { throw FolioError.persistenceFailure }
    }

    func save(_ record: ReceiptRecord) async throws {
        do {
            var record = record
            record.metadata.updatedAt = Date()
            try upsert(record)
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }

    func fetchRecord(id: UUID) async throws -> ReceiptRecord? {
        do { return try existingRecord(id: id) }
        catch { throw FolioError.persistenceFailure }
    }

    func delete(id: UUID) async throws {
        do {
            guard let stored = try storedReceipt(id: id) else { return }
            context.delete(stored)
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }

    func search(_ filter: ReceiptFilter) async throws -> [ReceiptRecord] {
        do {
            try ensureIndexed()

            // Predicates are static, so absent filters become neutral values.
            let start = filter.dateRange?.lowerBound ?? .distantPast
            let end = filter.dateRange?.upperBound ?? .distantFuture
            let retailer = filter.retailerName ?? ""
            let category = filter.category ?? ""
            let currency = filter.currencyCode ?? ""
            let profile = filter.profile?.rawValue ?? ""
            let minMinor = filter.minTotal.map(ReceiptFingerprint.minorUnits) ?? Int.min
            let maxMinor = filter.maxTotal.map(ReceiptFingerprint.minorUnits) ?? Int.max

            let predicate = #Predicate<StoredReceipt> { r in
                r.purchaseDate >= start && r.purchaseDate < end
                && (retailer.isEmpty || r.retailerName == retailer)
                && (category.isEmpty || r.category == category)
                && (currency.isEmpty || r.currencyCode == currency)
                && (profile.isEmpty || r.profileRaw == profile)
                && r.totalMinorUnits >= minMinor && r.totalMinorUnits <= maxMinor
            }

            let sort: [SortDescriptor<StoredReceipt>]
            switch filter.sort {
            case .dateDescending:     sort = [SortDescriptor(\.purchaseDate, order: .reverse)]
            case .dateAscending:      sort = [SortDescriptor(\.purchaseDate, order: .forward)]
            case .totalDescending:    sort = [SortDescriptor(\.totalMinorUnits, order: .reverse)]
            case .totalAscending:     sort = [SortDescriptor(\.totalMinorUnits, order: .forward)]
            case .retailerAscending:  sort = [SortDescriptor(\.retailerName, order: .forward)]
            }

            let stored = try context.fetch(FetchDescriptor<StoredReceipt>(predicate: predicate, sortBy: sort))

            let words = filter.searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let matching = words.isEmpty ? stored : stored.filter { r in
                words.allSatisfy { r.searchText.contains($0) }
            }

            var records = try matching.map(decode)
            if let tag = filter.tag?.lowercased(), !tag.isEmpty {
                records = records.filter { $0.metadata.tags.contains { $0.lowercased() == tag } }
            }
            return records
        } catch { throw FolioError.persistenceFailure }
    }

    func possibleDuplicates(of receipt: PurchaseReceipt) async throws -> [ReceiptRecord] {
        do {
            try ensureIndexed()
            let key = ReceiptFingerprint.make(for: receipt)
            let ownID = receipt.id
            let descriptor = FetchDescriptor<StoredReceipt>(
                predicate: #Predicate { $0.fingerprint == key && $0.id != ownID })
            return try context.fetch(descriptor).map(decode)
        } catch { throw FolioError.persistenceFailure }
    }

    /// Backfills query columns for receipts saved before they existed or before the index changed.
    private func ensureIndexed() throws {
        guard !indexUpToDate else { return }
        do {
            let current = ReceiptIndex.currentVersion
            let stale = try context.fetch(FetchDescriptor<StoredReceipt>(
                predicate: #Predicate { $0.indexVersion < current }))
            for stored in stale { stored.apply(ReceiptIndex(try decode(stored))) }
            if !stale.isEmpty { try context.save() }
            indexUpToDate = true
        } catch { context.rollback(); throw error }
    }

    private func storedReceipt(id: UUID) throws -> StoredReceipt? {
        let descriptor = FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func existingRecord(id: UUID) throws -> ReceiptRecord? {
        try storedReceipt(id: id).map(decode)
    }

    private func upsert(_ record: ReceiptRecord) throws {
        let payload = try ReceiptPayloadCodec.encode(record)
        let index = ReceiptIndex(record)
        if let stored = try storedReceipt(id: record.id) {
            stored.payload = payload
            stored.schemaVersion = ReceiptPayloadCodec.currentVersion
            stored.apply(index)
        } else {
            let stored = StoredReceipt(id: record.id, payload: payload)
            stored.schemaVersion = ReceiptPayloadCodec.currentVersion
            stored.apply(index)
            context.insert(stored)
        }
    }

    private func decode(_ stored: StoredReceipt) throws -> ReceiptRecord {
        try ReceiptPayloadCodec.decode(stored.payload, schemaVersion: stored.schemaVersion)
    }
}

@MainActor final class SwiftDataRetailerRepository: RetailerRepository {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([StoredRetailer.self])
        let configuration = ModelConfiguration("Retailers", schema: schema, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func fetchAll() async throws -> [SavedRetailer] {
        do {
            let descriptor = FetchDescriptor<StoredRetailer>(sortBy: [SortDescriptor(\.nameKey)])
            return try context.fetch(descriptor).map { try decode($0) }
        } catch { throw FolioError.persistenceFailure }
    }

    func save(_ retailer: SavedRetailer) async throws {
        do {
            let id = retailer.id
            let payload = try JSONEncoder().encode(retailer)
            let key = SavedRetailer.key(retailer.name)
            let descriptor = FetchDescriptor<StoredRetailer>(predicate: #Predicate { $0.id == id })
            if let stored = try context.fetch(descriptor).first {
                stored.name = retailer.name
                stored.nameKey = key
                stored.payload = payload
                stored.schemaVersion = 1
            } else {
                context.insert(StoredRetailer(id: id, name: retailer.name, nameKey: key, payload: payload))
            }
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }

    func delete(id: UUID) async throws {
        do {
            let descriptor = FetchDescriptor<StoredRetailer>(predicate: #Predicate { $0.id == id })
            guard let stored = try context.fetch(descriptor).first else { return }
            context.delete(stored)
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }

    private func decode(_ stored: StoredRetailer) throws -> SavedRetailer {
        guard stored.schemaVersion == 1 else { throw FolioError.persistenceFailure }
        return try JSONDecoder().decode(SavedRetailer.self, from: stored.payload)
    }
}

@MainActor final class SwiftDataReminderRepository: ReminderRepository {
    private let context: ModelContext
    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
    func save(_ reminder: ReturnReminder) async throws {
        do {
            let id = reminder.id
            let descriptor = FetchDescriptor<StoredReminder>(predicate: #Predicate { $0.id == id })
            let payload = try JSONEncoder().encode(reminder)
            if let record = try context.fetch(descriptor).first { record.payload = payload }
            else { context.insert(StoredReminder(id: id, payload: payload)) }
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }
    func fetchAll() async throws -> [ReturnReminder] {
        do {
            return try context.fetch(FetchDescriptor<StoredReminder>()).map {
                guard $0.schemaVersion == 1 else { throw FolioError.persistenceFailure }
                return try JSONDecoder().decode(ReturnReminder.self, from: $0.payload)
            }.sorted { $0.notifyAt < $1.notifyAt }
        } catch { throw FolioError.persistenceFailure }
    }
    func delete(id: UUID) async throws {
        do {
            let descriptor = FetchDescriptor<StoredReminder>(predicate: #Predicate { $0.id == id })
            guard let stored = try context.fetch(descriptor).first else { return }
            context.delete(stored)
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }
}
