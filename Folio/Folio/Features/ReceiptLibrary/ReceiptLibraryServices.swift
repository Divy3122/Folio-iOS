import Foundation

@MainActor struct ReceiptLibraryServices {
    let repository: any ReceiptLibraryRepository
    let images: any ReceiptImageStore
    var beforeDelete: (UUID) async throws -> Void = { _ in }

    init(container: DependencyContainer, images: (any ReceiptImageStore)? = nil) throws {
        guard let repository = container.receipts as? any ReceiptLibraryRepository else {
            throw FolioError.persistenceFailure
        }
        self.repository = repository
        self.images = try images ?? FileReceiptImageStore.makeDefault()
    }

    init(repository: any ReceiptLibraryRepository, images: any ReceiptImageStore) {
        self.repository = repository
        self.images = images
    }

    var searchReceipts: SearchReceipts { SearchReceipts(repository: repository) }
    var detectDuplicate: DetectDuplicateReceipt { DetectDuplicateReceipt(repository: repository) }
    var attachDetails: AttachReceiptDetails { AttachReceiptDetails(repository: repository, images: images) }
    var updateMetadata: UpdateReceiptMetadata { UpdateReceiptMetadata(repository: repository) }
    var deleteReceipt: DeleteReceipt {
        var delete = DeleteReceipt(repository: repository, images: images)
        delete.beforeDelete = beforeDelete
        return delete
    }
}
