import Foundation
import SwiftData

/// Dedicated context: rollback cannot discard another feature's pending changes.
@MainActor final class SwiftDataReceiptRepository: ReceiptRepository {
    private let context: ModelContext
    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
    func save(_ receipt: PurchaseReceipt) async throws {
        do {
            let id = receipt.id
            let descriptor = FetchDescriptor<StoredReceipt>(predicate: #Predicate { $0.id == id })
            let payload = try JSONEncoder().encode(receipt)
            if let record = try context.fetch(descriptor).first { record.payload = payload }
            else { context.insert(StoredReceipt(id: id, payload: payload)) }
            try context.save()
        } catch { context.rollback(); throw FolioError.persistenceFailure }
    }
    func fetchAll() async throws -> [PurchaseReceipt] {
        do {
            return try context.fetch(FetchDescriptor<StoredReceipt>()).map {
                guard $0.schemaVersion == 1 else { throw FolioError.persistenceFailure }
                return try JSONDecoder().decode(PurchaseReceipt.self, from: $0.payload)
            }
        } catch { throw FolioError.persistenceFailure }
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
}
