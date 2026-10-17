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

@MainActor struct DeleteReceipt {
    let repository: any ReceiptLibraryRepository
    let images: any ReceiptImageStore
    var beforeDelete: (UUID) async throws -> Void = { _ in }

    func callAsFunction(id: UUID) async throws {
        try await beforeDelete(id)
        try await repository.delete(id: id)
        try? images.delete(receiptID: id)
    }
}
