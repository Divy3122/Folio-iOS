import SwiftData

@MainActor final class DependencyContainer {
    let receipts: any ReceiptRepository
    let reminders: any ReminderRepository
    let scheduler: any ReminderScheduling

    var saveReceipt: SaveReceipt { SaveReceipt(repository: receipts) }
    var fetchReceipts: FetchReceipts { FetchReceipts(repository: receipts) }
    var calculateSpending: CalculateSpending { CalculateSpending(repository: receipts) }
    var createReturnReminder: CreateReturnReminder { CreateReturnReminder(receipts: receipts, reminders: reminders) }
    var loadReminderSummaries: LoadReminderSummaries { LoadReminderSummaries(reminders: reminders, receipts: receipts) }
    var deleteReturnReminder: DeleteReturnReminder { DeleteReturnReminder(reminders: reminders, scheduler: scheduler) }

    init(receipts: any ReceiptRepository,
         reminders: any ReminderRepository,
         scheduler: any ReminderScheduling = NotificationReminderScheduler()) {
        self.receipts = receipts
        self.reminders = reminders
        self.scheduler = scheduler
    }

    static func live() throws -> DependencyContainer {
        do {
            let schema = Schema([StoredReceipt.self, StoredReminder.self])
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return DependencyContainer(
                receipts: SwiftDataReceiptRepository(container: container),
                reminders: SwiftDataReminderRepository(container: container),
                scheduler: NotificationReminderScheduler()
            )
        } catch { throw FolioError.persistenceFailure }
    }
}
