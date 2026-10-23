import Foundation

@MainActor protocol ReceiptRepository {
    func save(_ receipt: PurchaseReceipt) async throws
    func update(_ receipt: PurchaseReceipt) async throws
    func fetchAll() async throws -> [PurchaseReceipt]
}

@MainActor protocol ReminderRepository {
    func save(_ reminder: ReturnReminder) async throws
    func fetchAll() async throws -> [ReturnReminder]
    func delete(id: UUID) async throws
}

protocol ReceiptTextRecognizing: Sendable {
    func recognize(imageData: Data) async throws -> String
}

protocol ReceiptExtracting: Sendable {
    func extract(text: String) async throws -> ReceiptExtractionResult
}

/// Scheduling is explicit and separate from durable reminder creation.
@MainActor protocol ReminderScheduling {
    func requestAuthorization() async throws -> Bool
    func schedule(_ reminder: ReturnReminder) async throws
    func cancel(id: UUID) async
}
