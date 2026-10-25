import XCTest
import SwiftData
@testable import Folio

@MainActor private final class FakeReminders: ReminderRepository {
    var items: [ReturnReminder]
    var failDelete = false

    init(_ items: [ReturnReminder] = []) { self.items = items }

    func save(_ reminder: ReturnReminder) async throws { items.append(reminder) }
    func fetchAll() async throws -> [ReturnReminder] { items }
    func delete(id: UUID) async throws {
        if failDelete { throw FolioError.persistenceFailure }
        items.removeAll { $0.id == id }
    }
}

@MainActor private final class FakeScheduler: ReminderScheduling {
    var cancelled: [UUID] = []

    func requestAuthorization() async throws -> Bool { true }
    func schedule(_ reminder: ReturnReminder) async throws {}
    func cancel(id: UUID) async { cancelled.append(id) }
}

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

    func testAppliedPoliciesAreStoredWithTheReceiptAndSearchable() async throws {
        let (repo, _) = try makeRepository()
        let receipt = makeReceipt("JB Hi-Fi", items: ["Headphones"])
        var record = ReceiptRecord(receipt: receipt)
        record.metadata.policies = [
            AppliedPolicy(kind: .warranty, title: "Manufacturer warranty", windowDays: 365, notes: "Keep serial")
        ]
        try await repo.save(record)
        try await repo.save(makeReceipt("Coles"))

        let found = try await repo.search(ReceiptFilter(searchText: "warranty"))
        XCTAssertEqual(found.map(\.id), [receipt.id])
        XCTAssertEqual(found.first?.metadata.policies.first?.windowDays, 365)
        XCTAssertEqual(found.first?.metadata.policies.first?.kind, .warranty)
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

    func testDeleteRemovesReceiptImagesAndRemindersAndCancelsNotifications() async throws {
        let (repo, _) = try makeRepository()
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = makeReceipt("Target")
        let other = makeReceipt("Kmart", total: 10)
        try await repo.save(receipt)
        try await repo.save(other)
        _ = try store.save([Data([9])], for: receipt.id)

        let first = ReturnReminder(receiptID: receipt.id, deadline: base, notifyAt: base)
        let second = ReturnReminder(receiptID: receipt.id, deadline: base, notifyAt: base)
        let unrelated = ReturnReminder(receiptID: other.id, deadline: base, notifyAt: base)
        let reminders = FakeReminders([first, second, unrelated])
        let scheduler = FakeScheduler()

        let delete = DeleteReceipt(repository: repo, images: store, reminders: reminders, scheduler: scheduler)
        try await delete(id: receipt.id)

        let gone = try await repo.fetchRecord(id: receipt.id)
        XCTAssertNil(gone)
        XCTAssertNil(try store.loadPage(0, for: receipt.id))
        XCTAssertEqual(reminders.items.map(\.id), [unrelated.id])
        XCTAssertEqual(Set(scheduler.cancelled), [first.id, second.id])
        let kept = try await repo.fetchRecord(id: other.id)
        XCTAssertNotNil(kept)
        try await delete(id: receipt.id)
    }

    func testFailedReminderDeletionKeepsTheReceipt() async throws {
        let (repo, _) = try makeRepository()
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = makeReceipt("Big W")
        try await repo.save(receipt)

        let reminders = FakeReminders([ReturnReminder(receiptID: receipt.id, deadline: base, notifyAt: base)])
        reminders.failDelete = true
        let scheduler = FakeScheduler()

        let delete = DeleteReceipt(repository: repo, images: store, reminders: reminders, scheduler: scheduler)
        do { try await delete(id: receipt.id); XCTFail("expected an error") } catch {}

        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertNotNil(fetched)
        XCTAssertTrue(scheduler.cancelled.isEmpty)
    }

    func testDeleteWithoutRemindersOrSchedulerStillRemovesTheReceipt() async throws {
        let (repo, _) = try makeRepository()
        let (store, folder) = try makeImageStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = makeReceipt("Aldi")
        try await repo.save(receipt)

        try await DeleteReceipt(repository: repo, images: store)(id: receipt.id)

        let fetched = try await repo.fetchRecord(id: receipt.id)
        XCTAssertNil(fetched)
    }

    func testRetailersPersistWithTheirPoliciesAndSortByName() async throws {
        let container = try ModelContainer(
            for: StoredRetailer.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let manage = ManageRetailers(repository: SwiftDataRetailerRepository(container: container))
        let policies = [
            SavedPolicy(kind: .returns, title: "Change of mind", windowDays: 30, notes: "Unopened"),
            SavedPolicy(kind: .warranty, title: "Manufacturer warranty", windowDays: 365)
        ]
        try await manage.save(SavedRetailer(name: "JB Hi-Fi", policies: policies))
        try await manage.save(SavedRetailer(name: "Bunnings"))

        let all = try await manage.all()
        XCTAssertEqual(all.map(\.name), ["Bunnings", "JB Hi-Fi"])
        XCTAssertEqual(all.last?.policies, policies)

        if let jb = all.last { try await manage.delete(id: jb.id) }
        let remaining = try await manage.all()
        XCTAssertEqual(remaining.map(\.name), ["Bunnings"])
    }

    func testRetailerNamesMustBeUniqueButEditingTheSameRetailerIsAllowed() async throws {
        let manage = ManageRetailers(repository: InMemoryRetailerRepository())
        var kmart = SavedRetailer(name: "Kmart")
        try await manage.save(kmart)

        do {
            try await manage.save(SavedRetailer(name: " kmart "))
            XCTFail("expected a duplicate error")
        } catch {
            XCTAssertEqual(error as? RetailerError, .duplicateName("kmart"))
        }

        kmart.name = "Kmart Australia"
        kmart.policies = [SavedPolicy(kind: .returns, title: "Change of mind", windowDays: 14)]
        try await manage.save(kmart)

        let all = try await manage.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Kmart Australia")
        XCTAssertEqual(all.first?.policies.count, 1)
    }

    func testInvalidRetailerAndPolicyAreRejected() async throws {
        let manage = ManageRetailers(repository: InMemoryRetailerRepository())

        do {
            try await manage.save(SavedRetailer(name: "  "))
            XCTFail("expected an empty name error")
        } catch {
            XCTAssertEqual(error as? RetailerError, .emptyName)
        }

        for policy in [SavedPolicy(kind: .returns, title: "Faulty", windowDays: 0),
                       SavedPolicy(kind: .warranty, title: " ", windowDays: 30),
                       SavedPolicy(kind: .warranty, title: "Too long", windowDays: 4000)] {
            do {
                try await manage.save(SavedRetailer(name: "Test", policies: [policy]))
                XCTFail("expected an invalid policy error")
            } catch {
                XCTAssertEqual(error as? RetailerError, .invalidPolicy)
            }
        }
    }

    func testWarrantyLengthConvertsBetweenMonthsAndDays() {
        XCTAssertEqual(WarrantyLength.days(months: 12), 365)
        XCTAssertEqual(WarrantyLength.months(days: 365), 12)
        XCTAssertEqual(WarrantyLength.days(months: 120), 3650)
        XCTAssertEqual(WarrantyLength.months(days: 10), 1)
        XCTAssertEqual(WarrantyLength.months(days: 0), 0)
        XCTAssertEqual(WarrantyLength.describe(months: 0), "None")
        XCTAssertEqual(WarrantyLength.describe(months: 18), "1 year 6 months")
        XCTAssertEqual(WarrantyLength.describe(months: 24), "2 years")
    }

    func testRetailerDefaultsAreTheShortestReturnAndFirstWarranty() {
        let short = SavedPolicy(kind: .returns, title: "Change of mind", windowDays: 30)
        let long = SavedPolicy(kind: .returns, title: "Faulty", windowDays: 365)
        let warranty = SavedPolicy(kind: .warranty, title: "Manufacturer", windowDays: 365)
        let retailer = SavedRetailer(name: "JB Hi-Fi", policies: [long, short, warranty])

        XCTAssertEqual(retailer.defaultReturnPolicyID, short.id)
        XCTAssertEqual(retailer.defaultWarrantyMonths, 12)
        XCTAssertNil(SavedRetailer(name: "Empty").defaultReturnPolicyID)
        XCTAssertEqual(SavedRetailer(name: "Empty").defaultWarrantyMonths, 0)
    }

    func testChoosingARetailerAppliesOnlySelectedPoliciesWithoutChangingTheirDuration() {
        let short = SavedPolicy(kind: .returns, title: "Change of mind", windowDays: 30)
        let long = SavedPolicy(kind: .returns, title: "Faulty", windowDays: 365)
        let warranty = SavedPolicy(kind: .warranty, title: "Manufacturer", windowDays: 365)
        let retailer = SavedRetailer(name: "JB Hi-Fi", policies: [short, long, warranty])
        let model = ReceiptSaveViewModel(costs: ReceiptCostBreakdown(), pages: [])

        model.applyRetailerChoice(retailer, selectedPolicies: [long, warranty])

        XCTAssertEqual(model.retailer, "JB Hi-Fi")
        XCTAssertEqual(model.selectedRetailerID, retailer.id)
        XCTAssertEqual(model.policyDrafts.first { $0.id == short.id }?.applies, false)
        XCTAssertEqual(model.policyDrafts.first { $0.id == long.id }?.applies, true)
        let warrantyDraft = model.policyDrafts.first { $0.id == warranty.id }
        XCTAssertEqual(warrantyDraft?.applies, true)
        XCTAssertEqual(warrantyDraft?.daysText, String(warranty.windowDays))
    }

    func testChoosingNoPoliciesAppliesNothingAndUnknownPoliciesAreNotAdded() {
        let short = SavedPolicy(kind: .returns, title: "Change of mind", windowDays: 30)
        let retailer = SavedRetailer(name: "Kmart", policies: [short])
        let model = ReceiptSaveViewModel(costs: ReceiptCostBreakdown(), pages: [])

        model.applyRetailerChoice(retailer, selectedPolicies: [])
        XCTAssertTrue(model.policyDrafts.allSatisfy { !$0.applies })

        let unavailableWarranty = SavedPolicy(kind: .warranty, title: "Warranty", windowDays: WarrantyLength.days(months: 6))
        model.applyRetailerChoice(retailer, selectedPolicies: [short, unavailableWarranty])
        XCTAssertEqual(model.policyDrafts.count, 1)
        XCTAssertEqual(model.policyDrafts.first { $0.id == short.id }?.applies, true)
        XCTAssertNil(model.policyDrafts.first { $0.kind == .warranty })
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
