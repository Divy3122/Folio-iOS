import Foundation
import SwiftData
import Testing
@testable import Folio

@MainActor private final class ReceiptMock: ReceiptRepository {
    var values: [PurchaseReceipt] = []
    var fail = false
    func save(_ receipt: PurchaseReceipt) async throws {
        if fail { throw FolioError.persistenceFailure }
        values.append(receipt)
    }
    func fetchAll() async throws -> [PurchaseReceipt] {
        if fail { throw FolioError.persistenceFailure }
        return values
    }
}
@MainActor private final class ReminderMock: ReminderRepository {
    var values: [ReturnReminder] = []
    var fail = false
    func save(_ reminder: ReturnReminder) async throws {
        if fail { throw FolioError.persistenceFailure }
        values.append(reminder)
    }
    func fetchAll() async throws -> [ReturnReminder] { values }
    func delete(id: UUID) async throws { values.removeAll { $0.id == id } }
}

@MainActor struct FolioTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func receipt(total: Decimal = 12, currency: String = "AUD") -> PurchaseReceipt {
        PurchaseReceipt(retailer: Retailer(name: "Example"), purchasedAt: date,
                        currencyCode: currency, total: total, returnPolicy: ReturnPolicy(windowDays: 30, notes: "Confirmed"))
    }
    @Test func validReceiptIsSaved() async throws {
        let repository = ReceiptMock()
        let value = receipt()
        try await SaveReceipt(repository: repository)(value)
        #expect(repository.values == [value])
    }
    @Test func invalidReceiptsNeverReachStorage() async {
        let repository = ReceiptMock()
        var emptyRetailer = receipt(); emptyRetailer.retailer.name = "  "
        var badItem = receipt(); badItem.items = [PurchasedItem(name: "Item", quantity: 0, unitPrice: 1)]
        for value in [receipt(total: -1), receipt(total: .nan), receipt(currency: "???"), emptyRetailer, badItem] {
            await #expect(throws: FolioError.invalidReceipt) { try await SaveReceipt(repository: repository)(value) }
        }
        #expect(repository.values.isEmpty)
    }
    @Test func repositoryFailuresPropagate() async {
        let repository = ReceiptMock(); repository.fail = true
        await #expect(throws: FolioError.persistenceFailure) { try await SaveReceipt(repository: repository)(receipt()) }
        await #expect(throws: FolioError.persistenceFailure) { try await FetchReceipts(repository: repository)() }
        await #expect(throws: FolioError.persistenceFailure) {
            try await CalculateSpending(repository: repository)(from: date, to: date.addingTimeInterval(1))
        }
    }
    @Test func spendingSeparatesCurrenciesAndExcludesEndBoundary() async throws {
        let repository = ReceiptMock()
        var excluded = receipt(total: 999); excluded.purchasedAt = date.addingTimeInterval(60)
        repository.values = [receipt(total: Decimal(string: "0.1")!), receipt(total: Decimal(string: "0.2")!), receipt(total: 5, currency: "USD"), excluded]
        let totals = try await CalculateSpending(repository: repository)(from: date, to: date.addingTimeInterval(60))
        #expect(totals == ["AUD": Decimal(string: "0.3")!, "USD": 5])
        await #expect(throws: FolioError.invalidDateRange) {
            try await CalculateSpending(repository: repository)(from: date, to: date)
        }
    }
    @Test func receiptsSortNewestFirst() async throws {
        let repository = ReceiptMock()
        var older = receipt(); older.purchasedAt = date.addingTimeInterval(-60)
        let newer = receipt(); repository.values = [older, newer]
        #expect(try await FetchReceipts(repository: repository)() == [newer, older])
    }
    @Test func reminderRulesAndStorageFailures() async throws {
        let receipts = ReceiptMock(); let reminders = ReminderMock()
        let value = receipt(); receipts.values = [value]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let useCase = CreateReturnReminder(receipts: receipts, reminders: reminders, calendar: calendar, now: { date })
        let reminder = try await useCase(receiptID: value.id, notifyAt: date.addingTimeInterval(60))
        #expect(reminder.deadline == calendar.date(byAdding: .day, value: 30, to: date))
        #expect(reminders.values == [reminder])
        await #expect(throws: FolioError.invalidReminderDate) { try await useCase(receiptID: value.id, notifyAt: date) }
        await #expect(throws: FolioError.invalidReminderDate) { try await useCase(receiptID: value.id, notifyAt: reminder.deadline.addingTimeInterval(1)) }
        await #expect(throws: FolioError.receiptNotFound) { try await useCase(receiptID: UUID(), notifyAt: date) }
        reminders.fail = true
        await #expect(throws: FolioError.persistenceFailure) { try await useCase(receiptID: value.id, notifyAt: date.addingTimeInterval(60)) }
        receipts.values[0].returnPolicy = nil
        await #expect(throws: FolioError.invalidReturnPolicy) { try await useCase(receiptID: value.id, notifyAt: date.addingTimeInterval(60)) }
    }
    @Test func swiftDataRoundTripAndUpsert() async throws {
        let schema = Schema([StoredReceipt.self, StoredReminder.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let repository = SwiftDataReceiptRepository(container: container)
        var value = receipt(); try await repository.save(value)
        value.total = 25; try await repository.save(value)
        let reader = SwiftDataReceiptRepository(container: container)
        #expect(try await reader.fetchAll() == [value])
        let reminders = SwiftDataReminderRepository(container: container)
        var reminder = ReturnReminder(receiptID: value.id, deadline: date, notifyAt: date)
        try await reminders.save(reminder)
        reminder.notifyAt = date.addingTimeInterval(-60)
        try await reminders.save(reminder)
        #expect(try await SwiftDataReminderRepository(container: container).fetchAll() == [reminder])
    }
    @Test func corruptDataIsReportedNotSilentlyDropped() async throws {
        let schema = Schema([StoredReceipt.self, StoredReminder.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        context.insert(StoredReceipt(id: UUID(), payload: Data("invalid".utf8)))
        try context.save()
        await #expect(throws: FolioError.persistenceFailure) { try await SwiftDataReceiptRepository(container: container).fetchAll() }
    }
}
