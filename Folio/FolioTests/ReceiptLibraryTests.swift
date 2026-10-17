import XCTest
import SwiftData
@testable import Folio

@MainActor
final class ReceiptLibraryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)
    private let day: TimeInterval = 86_400

    private func makeRepository() throws -> (SwiftDataReceiptRepository, ModelContainer) {
        let container = try ModelContainer(
            for: StoredReceipt.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (SwiftDataReceiptRepository(container: container), container)
    }

    private func makeImageStore() throws -> (FileReceiptImageStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try FileReceiptImageStore(root: folder), folder)
    }

    private func makeReceipt(_ retailer: String, total: Decimal = 50, at date: Date? = nil,
                             profile: PurchaseProfile = .personal, items: [String] = []) -> PurchaseReceipt {
        PurchaseReceipt(
            retailer: Retailer(name: retailer), purchasedAt: date ?? base, currencyCode: "AUD", total: total,
            items: items.map { PurchasedItem(name: $0, quantity: 1, unitPrice: 10) }, profile: profile)
    }

    func testSaveAndFetchRoundTripKeepsReceiptAndMetadata() async throws {
        let (repo, _) = try makeRepository()
        let receipt = makeReceipt("JB Hi-Fi", total: 199, items: ["Headphones"])
        var record = ReceiptRecord(receipt: receipt)
        record.metadata.category = "Electronics"
        record.metadata.tags = ["warranty"]
        try await repo.save(record)

        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertEqual(fetched?.receipt, receipt)
        XCTAssertEqual(fetched?.metadata.category, "Electronics")
        XCTAssertEqual(fetched?.metadata.tags, ["warranty"])
    }

    func testSavingBareReceiptKeepsExistingMetadata() async throws {
        let (repo, _) = try makeRepository()
        var receipt = makeReceipt("Coles")
        var record = ReceiptRecord(receipt: receipt)
        record.metadata.notes = "Weekly shop"
        try await repo.save(record)

        receipt.total = 75
        try await repo.save(receipt)

        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertEqual(fetched?.receipt.total, 75)
        XCTAssertEqual(fetched?.metadata.notes, "Weekly shop")
    }

    func testSearchRequiresEveryWordToMatch() async throws {
        let (repo, _) = try makeRepository()
        try await repo.save(makeReceipt("JB Hi-Fi", items: ["Headphones"]))
        try await repo.save(makeReceipt("JB Hi-Fi", items: ["Speaker"]))
        try await repo.save(makeReceipt("Woolworths", items: ["Headphones cleaner"]))

        let results = try await repo.search(ReceiptFilter(searchText: "jb headphones"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.receipt.retailer.name, "JB Hi-Fi")
    }

    func testProfileAndDateFiltersNarrowResults() async throws {
        let (repo, _) = try makeRepository()
        try await repo.save(makeReceipt("Old personal", at: base.addingTimeInterval(-10 * day)))
        try await repo.save(makeReceipt("Recent personal", at: base))
        try await repo.save(makeReceipt("Recent business", at: base, profile: .business))

        let range = base.addingTimeInterval(-5 * day)..<base.addingTimeInterval(day)
        let results = try await repo.search(ReceiptFilter(dateRange: range, profile: .personal))
        XCTAssertEqual(results.map(\.receipt.retailer.name), ["Recent personal"])
    }

    func testDuplicateDetectionIgnoresItselfAndRespectsTotals() async throws {
        let (repo, _) = try makeRepository()
        let original = makeReceipt("Kmart", total: 42)
        try await repo.save(original)

        let ofItself = try await repo.possibleDuplicates(of: original)
        XCTAssertTrue(ofItself.isEmpty)

        let sameDetails = makeReceipt("kmart ", total: 42)
        let dupes = try await repo.possibleDuplicates(of: sameDetails)
        XCTAssertEqual(dupes.map(\.id), [original.id])

        let differentTotal = makeReceipt("Kmart", total: 43)
        let none = try await repo.possibleDuplicates(of: differentTotal)
        XCTAssertTrue(none.isEmpty)
    }

    func testReceiptsSavedInTheOldFormatAreFoundByTheFirstSearch() async throws {
        let (repo, container) = try makeRepository()
        let old = makeReceipt("Bunnings", total: 120, items: ["Drill"])
        let context = ModelContext(container)
        context.insert(StoredReceipt(id: old.id, payload: try JSONEncoder().encode(old)))
        try context.save()

        let found = try await repo.search(ReceiptFilter(searchText: "drill"))
        XCTAssertEqual(found.map(\.receipt), [old])
    }

    func testAttachReceiptDetailsStoresPagesCostsAndSource() async throws {
        let (repo, _) = try makeRepository()
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = makeReceipt("Officeworks", total: 30)
        try await repo.save(receipt)

        var costs = ReceiptCostBreakdown()
        costs.total = 30
        try await AttachReceiptDetails(repository: repo, images: store)(
            receiptID: receipt.id, costs: costs, source: .foundationModels,
            pages: [Data([1]), Data([2])])

        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertEqual(fetched?.costs?.total, 30)
        XCTAssertEqual(fetched?.metadata.imageCount, 2)
        XCTAssertEqual(fetched?.metadata.extractionSource, .foundationModels)
        XCTAssertEqual(try store.loadPage(1, for: receipt.id), Data([2]))
    }

    func testDeleteRemovesReceiptAndImagesAndRunsHookFirst() async throws {
        let (repo, _) = try makeRepository()
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = makeReceipt("Target")
        try await repo.save(receipt)
        _ = try store.save([Data([9])], for: receipt.id)

        var hookedID: UUID?
        var delete = DeleteReceipt(repository: repo, images: store)
        delete.beforeDelete = { hookedID = $0 }
        try await delete(id: receipt.id)

        XCTAssertEqual(hookedID, receipt.id)
        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertNil(fetched)
        XCTAssertNil(try store.loadPage(0, for: receipt.id))
        try await delete(id: receipt.id)
    }

    func testFailedHookKeepsTheReceipt() async throws {
        let (repo, _) = try makeRepository()
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = makeReceipt("Big W")
        try await repo.save(receipt)

        var delete = DeleteReceipt(repository: repo, images: store)
        delete.beforeDelete = { _ in throw FolioError.persistenceFailure }
        do { try await delete(id: receipt.id); XCTFail("expected an error") } catch {}

        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertNotNil(fetched)
    }

    func testImageStoreSavesLoadsAndDeletesPages() throws {
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()

        XCTAssertEqual(try store.save([Data([1, 2, 3]), Data([4, 5])], for: id), 2)
        XCTAssertEqual(try store.loadPage(1, for: id), Data([4, 5]))
        XCTAssertNil(try store.loadPage(2, for: id))

        try store.delete(receiptID: id)
        XCTAssertNil(try store.loadPage(0, for: id))
        XCTAssertNoThrow(try store.delete(receiptID: id))
    }

    func testTagNormalisationTrimsAndRemovesCaseInsensitiveDuplicates() {
        let tags = UpdateReceiptMetadata.normalised([" Work ", "work", "", "Tax", "TAX"])
        XCTAssertEqual(tags, ["Work", "Tax"])
    }
}
