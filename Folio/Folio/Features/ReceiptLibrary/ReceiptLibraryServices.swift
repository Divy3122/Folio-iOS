import Foundation

@MainActor struct ReceiptLibraryServices {
    let repository: any ReceiptLibraryRepository
    let images: any ReceiptImageStore
    let retailers: any RetailerRepository
    let reminders: (any ReminderRepository)?
    var scheduler: (any ReminderScheduling)?

    init(container: DependencyContainer, images: (any ReceiptImageStore)? = nil,
         retailers: (any RetailerRepository)? = nil, scheduler: (any ReminderScheduling)? = nil) throws {
        guard let repository = container.receipts as? any ReceiptLibraryRepository else {
            throw FolioError.persistenceFailure
        }
        self.repository = repository
        self.images = try images ?? FileReceiptImageStore.makeDefault()
        self.retailers = try retailers ?? SwiftDataRetailerRepository(container: SwiftDataRetailerRepository.makeContainer())
        self.reminders = container.reminders
        self.scheduler = scheduler
    }

    init(repository: any ReceiptLibraryRepository, images: any ReceiptImageStore,
         retailers: any RetailerRepository = InMemoryRetailerRepository(),
         reminders: (any ReminderRepository)? = nil, scheduler: (any ReminderScheduling)? = nil) {
        self.repository = repository
        self.images = images
        self.retailers = retailers
        self.reminders = reminders
        self.scheduler = scheduler
    }

    var searchReceipts: SearchReceipts { SearchReceipts(repository: repository) }
    var detectDuplicate: DetectDuplicateReceipt { DetectDuplicateReceipt(repository: repository) }
    var attachDetails: AttachReceiptDetails { AttachReceiptDetails(repository: repository, images: images) }
    var updateMetadata: UpdateReceiptMetadata { UpdateReceiptMetadata(repository: repository) }
    var manageRetailers: ManageRetailers { ManageRetailers(repository: retailers) }
    var deleteReceipt: DeleteReceipt {
        DeleteReceipt(repository: repository, images: images, reminders: reminders, scheduler: scheduler)
    }

    // MARK: - Direct Record & Receipt Access

    func fetchRecord(id: UUID) async throws -> ReceiptRecord? {
        try await repository.fetchRecord(id: id)
    }

    func updateReceipt(_ receipt: PurchaseReceipt) async throws {
        var record = try await repository.fetchRecord(id: receipt.id) ?? ReceiptRecord(receipt: receipt)
        record.receipt = receipt
        record.metadata.updatedAt = Date()
        try await repository.save(record)
    }

    func saveRecord(_ record: ReceiptRecord) async throws {
        try await repository.save(record)
    }
}

@MainActor final class InMemoryRetailerRepository: RetailerRepository {
    private var items: [UUID: SavedRetailer] = [:]

    func fetchAll() async throws -> [SavedRetailer] {
        items.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ retailer: SavedRetailer) async throws { items[retailer.id] = retailer }

    func delete(id: UUID) async throws { items[id] = nil }
}
