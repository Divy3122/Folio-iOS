import SwiftData

@MainActor final class DependencyContainer {
    let receipts: any ReceiptRepository
    let reminders: any ReminderRepository
    var saveReceipt: SaveReceipt { SaveReceipt(repository: receipts) }
    var fetchReceipts: FetchReceipts { FetchReceipts(repository: receipts) }
    var calculateSpending: CalculateSpending { CalculateSpending(repository: receipts) }
    var createReturnReminder: CreateReturnReminder { CreateReturnReminder(receipts: receipts, reminders: reminders) }

    init(receipts: any ReceiptRepository, reminders: any ReminderRepository) {
        self.receipts = receipts; self.reminders = reminders
    }
    static func live() throws -> DependencyContainer {
        do {
            let schema = Schema([StoredReceipt.self, StoredReminder.self])
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return DependencyContainer(receipts: SwiftDataReceiptRepository(container: container),
                                       reminders: SwiftDataReminderRepository(container: container))
        } catch { throw FolioError.persistenceFailure }
    }
}
