import Foundation

@MainActor struct SearchReceipts {
    let repository: any ReceiptLibraryRepository
    func callAsFunction(_ filter: ReceiptFilter) async throws -> [ReceiptRecord] {
        try await repository.search(filter)
    }
}

@MainActor struct DetectDuplicateReceipt {
    let repository: any ReceiptLibraryRepository
    func callAsFunction(_ receipt: PurchaseReceipt) async throws -> [ReceiptRecord] {
        try await repository.possibleDuplicates(of: receipt)
    }
}

@MainActor struct AttachReceiptDetails {
    let repository: any ReceiptLibraryRepository
    let images: any ReceiptImageStore

    func callAsFunction(receiptID: UUID, costs: ReceiptCostBreakdown?,
                        source: ReceiptMetadata.ExtractionSource?, pages: [Data]) async throws {
        guard var record = try await repository.fetchRecord(id: receiptID) else {
            throw FolioError.receiptNotFound
        }
        if !pages.isEmpty { record.metadata.imageCount = try images.save(pages, for: receiptID) }
        record.costs = costs
        record.metadata.extractionSource = source
        try await repository.save(record)
    }
}

@MainActor struct UpdateReceiptMetadata {
    let repository: any ReceiptLibraryRepository

    func callAsFunction(id: UUID, _ change: (inout ReceiptMetadata) -> Void) async throws {
        guard var record = try await repository.fetchRecord(id: id) else { throw FolioError.receiptNotFound }
        change(&record.metadata)
        record.metadata.category = record.metadata.category.trimmingCharacters(in: .whitespacesAndNewlines)
        record.metadata.tags = Self.normalised(record.metadata.tags)
        try await repository.save(record)
    }

    static func normalised(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

@MainActor struct ManageRetailers {
    let repository: any RetailerRepository

    func all() async throws -> [SavedRetailer] {
        try await repository.fetchAll()
    }

    func save(_ retailer: SavedRetailer) async throws {
        var retailer = retailer
        retailer.name = retailer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !retailer.name.isEmpty else { throw RetailerError.emptyName }

        retailer.policies = try retailer.policies.map { original in
            var policy = original
            policy.title = policy.title.trimmingCharacters(in: .whitespacesAndNewlines)
            policy.notes = policy.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !policy.title.isEmpty, (1...3650).contains(policy.windowDays) else {
                throw RetailerError.invalidPolicy
            }
            return policy
        }

        let key = SavedRetailer.key(retailer.name)
        let others = try await repository.fetchAll().filter { $0.id != retailer.id }
        guard !others.contains(where: { SavedRetailer.key($0.name) == key }) else {
            throw RetailerError.duplicateName(retailer.name)
        }
        try await repository.save(retailer)
    }

    func delete(id: UUID) async throws {
        try await repository.delete(id: id)
    }
}

/// Deletes a receipt, its reminders (cancelling their notifications) and its page images.
/// Reminders go first: if one cannot be removed the receipt is kept, because a reminder
/// for a deleted receipt would still fire. Without a scheduler only the stored reminders go.
@MainActor struct DeleteReceipt {
    let repository: any ReceiptLibraryRepository
    let images: any ReceiptImageStore
    var reminders: (any ReminderRepository)?
    var scheduler: (any ReminderScheduling)?

    func callAsFunction(id: UUID) async throws {
        if let reminders {
            for reminder in try await reminders.fetchAll() where reminder.receiptID == id {
                try await reminders.delete(id: reminder.id)
                await scheduler?.cancel(id: reminder.id)
            }
        }
        try await repository.delete(id: id)
        try? images.delete(receiptID: id)
    }
}
