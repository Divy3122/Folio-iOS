import Foundation

@MainActor struct SaveReceipt {
    let repository: any ReceiptRepository

    func callAsFunction(_ receipt: PurchaseReceipt) async throws {
        guard !receipt.retailer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Locale.commonISOCurrencyCodes.contains(receipt.currencyCode),
              !receipt.total.isNaN, receipt.total >= 0,
              receipt.items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.quantity > 0 && !$0.unitPrice.isNaN && $0.unitPrice >= 0 }),
              receipt.returnPolicy.map({ $0.windowDays > 0 }) ?? true else {
            throw FolioError.invalidReceipt
        }
        try await repository.save(receipt)
    }
}

@MainActor struct FetchReceipts {
    let repository: any ReceiptRepository
    func callAsFunction() async throws -> [PurchaseReceipt] {
        try await repository.fetchAll().sorted {
            $0.purchasedAt == $1.purchasedAt ? $0.id.uuidString < $1.id.uuidString : $0.purchasedAt > $1.purchasedAt
        }
    }
}

@MainActor struct CalculateSpending {
    let repository: any ReceiptRepository
    /// Half-open interval [start, end). Never combine different currencies.
    func callAsFunction(from start: Date, to end: Date) async throws -> [String: Decimal] {
        guard start < end else { throw FolioError.invalidDateRange }
        let receipts = try await repository.fetchAll()
        return receipts.filter { $0.purchasedAt >= start && $0.purchasedAt < end }
            .reduce(into: [:]) { $0[$1.currencyCode, default: 0] += $1.total }
    }
}

@MainActor struct CreateReturnReminder {
    let receipts: any ReceiptRepository
    let reminders: any ReminderRepository
    var calendar: Calendar = .current
    var now: () -> Date = Date.init

    func callAsFunction(receiptID: UUID, notifyAt: Date) async throws -> ReturnReminder {
        guard let receipt = try await receipts.fetchAll().first(where: { $0.id == receiptID }) else {
            throw FolioError.receiptNotFound
        }
        guard let policy = receipt.returnPolicy, policy.windowDays > 0,
              let deadline = calendar.date(byAdding: .day, value: policy.windowDays, to: receipt.purchasedAt) else {
            throw FolioError.invalidReturnPolicy
        }
        guard notifyAt > now(), notifyAt <= deadline else { throw FolioError.invalidReminderDate }
        let reminder = ReturnReminder(receiptID: receiptID, deadline: deadline, notifyAt: notifyAt)
        try await reminders.save(reminder)
        return reminder
    }
}
