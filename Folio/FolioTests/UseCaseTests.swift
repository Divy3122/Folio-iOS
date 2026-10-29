//
//  UseCaseTests.swift
//  FolioTests
//
//  Comprehensive test suite covering all 16 domain/feature use cases,
//  all business validation rules, and repository error mapping with mock data layers.
//

import Foundation
import SwiftData
import Testing
@testable import Folio

// MARK: - Mock Data Layer Repositories & Services

@MainActor
private final class MockReceiptRepository: ReceiptRepository {
    var receipts: [PurchaseReceipt] = []
    var shouldThrowError: Error?

    func save(_ receipt: PurchaseReceipt) async throws {
        if let error = shouldThrowError { throw error }
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
    }

    func update(_ receipt: PurchaseReceipt) async throws {
        if let error = shouldThrowError { throw error }
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
    }

    func fetchAll() async throws -> [PurchaseReceipt] {
        if let error = shouldThrowError { throw error }
        return receipts
    }
}

@MainActor
private final class MockReminderRepository: ReminderRepository {
    var reminders: [ReturnReminder] = []
    var shouldThrowError: Error?

    func save(_ reminder: ReturnReminder) async throws {
        if let error = shouldThrowError { throw error }
        reminders.removeAll { $0.id == reminder.id }
        reminders.append(reminder)
    }

    func fetchAll() async throws -> [ReturnReminder] {
        if let error = shouldThrowError { throw error }
        return reminders
    }

    func delete(id: UUID) async throws {
        if let error = shouldThrowError { throw error }
        reminders.removeAll { $0.id == id }
    }
}

@MainActor
private final class MockReminderScheduler: ReminderScheduling {
    var scheduled: [ReturnReminder] = []
    var cancelled: [UUID] = []
    var authorizationGranted = true

    func requestAuthorization() async throws -> Bool {
        authorizationGranted
    }

    func schedule(_ reminder: ReturnReminder) async throws {
        scheduled.append(reminder)
    }

    func cancel(id: UUID) async {
        cancelled.append(id)
    }
}

@MainActor
private final class MockCompanyRepository: CompanyRepository {
    var companies: [Company] = []
    var shouldThrowError: Error?

    func fetchAll() async throws -> [Company] {
        if let error = shouldThrowError { throw error }
        return companies
    }

    func save(_ company: Company) async throws {
        if let error = shouldThrowError { throw error }
        companies.removeAll { $0.id == company.id }
        companies.append(company)
    }
}

@MainActor
private final class MockReceiptLibraryRepository: ReceiptLibraryRepository {
    var records: [UUID: ReceiptRecord] = [:]
    var duplicatesToReturn: [ReceiptRecord] = []
    var searchResultsToReturn: [ReceiptRecord]?
    var shouldThrowError: Error?

    func save(_ record: ReceiptRecord) async throws {
        if let error = shouldThrowError { throw error }
        records[record.id] = record
    }

    func fetchRecord(id: UUID) async throws -> ReceiptRecord? {
        if let error = shouldThrowError { throw error }
        return records[id]
    }

    func search(_ filter: ReceiptFilter) async throws -> [ReceiptRecord] {
        if let error = shouldThrowError { throw error }
        if let custom = searchResultsToReturn { return custom }
        return Array(records.values)
    }

    func delete(id: UUID) async throws {
        if let error = shouldThrowError { throw error }
        records.removeValue(forKey: id)
    }

    func possibleDuplicates(of receipt: PurchaseReceipt) async throws -> [ReceiptRecord] {
        if let error = shouldThrowError { throw error }
        return duplicatesToReturn
    }
}

@MainActor
private final class MockRetailerRepository: RetailerRepository {
    var retailers: [UUID: SavedRetailer] = [:]
    var shouldThrowError: Error?

    func fetchAll() async throws -> [SavedRetailer] {
        if let error = shouldThrowError { throw error }
        return Array(retailers.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ retailer: SavedRetailer) async throws {
        if let error = shouldThrowError { throw error }
        retailers[retailer.id] = retailer
    }

    func delete(id: UUID) async throws {
        if let error = shouldThrowError { throw error }
        retailers.removeValue(forKey: id)
    }
}

private final class MockReceiptImageStore: ReceiptImageStore {
    var storedPages: [UUID: [Data]] = [:]
    var shouldThrowError: Error?

    func save(_ pages: [Data], for receiptID: UUID) throws -> Int {
        if let error = shouldThrowError { throw error }
        storedPages[receiptID] = pages
        return pages.count
    }

    func loadPage(_ index: Int, for receiptID: UUID) throws -> Data? {
        if let error = shouldThrowError { throw error }
        guard let pages = storedPages[receiptID], pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    func delete(receiptID: UUID) throws {
        if let error = shouldThrowError { throw error }
        storedPages.removeValue(forKey: receiptID)
    }
}

// MARK: - UseCaseTests Suite

@Suite("All Application Use Cases, Business Validation Rules & Error Mapping")
@MainActor
struct UseCaseTests {
    private let testDate = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeReceipt(
        id: UUID = UUID(),
        retailer: String = "Acme Store",
        total: Decimal = 100,
        currencyCode: String = "AUD",
        purchasedAt: Date? = nil,
        items: [PurchasedItem] = [],
        returnWindowDays: Int? = 30
    ) -> PurchaseReceipt {
        PurchaseReceipt(
            id: id,
            retailer: Retailer(name: retailer),
            purchasedAt: purchasedAt ?? testDate,
            currencyCode: currencyCode,
            total: total,
            items: items.isEmpty ? [PurchasedItem(name: "Widget", quantity: 1, unitPrice: total)] : items,
            returnPolicy: returnWindowDays.map { ReturnPolicy(windowDays: $0, notes: "Standard return") }
        )
    }

    // MARK: - 1. Receipt Domain Use Cases & Business Validation

    @Test("SaveReceipt saves valid receipt and rejects every business validation violation")
    func testSaveReceiptValidation() async throws {
        let repo = MockReceiptRepository()
        let saveReceipt = SaveReceipt(repository: repo)

        // Valid receipt succeeds
        let validReceipt = makeReceipt()
        try await saveReceipt(validReceipt)
        #expect(repo.receipts.count == 1)
        #expect(repo.receipts.first?.id == validReceipt.id)

        // 1. Empty / whitespace retailer name
        var emptyRetailer = makeReceipt(); emptyRetailer.retailer.name = "   "
        // 2. Invalid ISO currency code
        var badCurrency = makeReceipt(); badCurrency.currencyCode = "XYZ_BAD"
        // 3. Negative total
        var negativeTotal = makeReceipt(); negativeTotal.total = -0.01
        // 4. NaN total
        var nanTotal = makeReceipt(); nanTotal.total = Decimal.nan
        // 5. Item with empty / whitespace name
        let emptyItemName = makeReceipt(items: [PurchasedItem(name: "  ", quantity: 1, unitPrice: 10)])
        // 6. Item with 0 or negative quantity
        let zeroQuantity = makeReceipt(items: [PurchasedItem(name: "Item", quantity: 0, unitPrice: 10)])
        let negativeQuantity = makeReceipt(items: [PurchasedItem(name: "Item", quantity: -2, unitPrice: 10)])
        // 7. Item with negative unit price
        let negativeUnitPrice = makeReceipt(items: [PurchasedItem(name: "Item", quantity: 1, unitPrice: -5)])
        // 8. Item with NaN unit price
        let nanUnitPrice = makeReceipt(items: [PurchasedItem(name: "Item", quantity: 1, unitPrice: Decimal.nan)])
        // 9. Return policy with zero or negative window days
        let zeroWindow = makeReceipt(returnWindowDays: 0)
        let negativeWindow = makeReceipt(returnWindowDays: -10)

        let invalidCases = [
            emptyRetailer, badCurrency, negativeTotal, nanTotal,
            emptyItemName, zeroQuantity, negativeQuantity,
            negativeUnitPrice, nanUnitPrice, zeroWindow, negativeWindow
        ]

        for invalid in invalidCases {
            await #expect(throws: FolioError.invalidReceipt) {
                try await saveReceipt(invalid)
            }
        }
    }

    @Test("FetchReceipts returns receipts sorted by date descending with secondary UUID sort")
    func testFetchReceiptsSorting() async throws {
        let repo = MockReceiptRepository()
        let fetchReceipts = FetchReceipts(repository: repo)

        let date1 = testDate.addingTimeInterval(-7200)
        let date2 = testDate
        let idA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let idB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let older = makeReceipt(id: UUID(), purchasedAt: date1)
        let sameDateA = makeReceipt(id: idA, purchasedAt: date2)
        let sameDateB = makeReceipt(id: idB, purchasedAt: date2)
        repo.receipts = [older, sameDateB, sameDateA]

        let fetched = try await fetchReceipts()
        #expect(fetched.count == 3)
        // Same date sorted by UUID ascending
        #expect(fetched[0].id == idA)
        #expect(fetched[1].id == idB)
        #expect(fetched[2].id == older.id)
    }

    @Test("CalculateSpending validates half-open date interval, excludes end boundary, and separates currencies")
    func testCalculateSpendingRules() async throws {
        let repo = MockReceiptRepository()
        let calculateSpending = CalculateSpending(repository: repo)

        let start = testDate
        let end = testDate.addingTimeInterval(3600)

        let insideStart = makeReceipt(total: 40, currencyCode: "AUD", purchasedAt: start)
        let insideMiddle = makeReceipt(total: 60, currencyCode: "AUD", purchasedAt: start.addingTimeInterval(1800))
        let insideUSD = makeReceipt(total: 25, currencyCode: "USD", purchasedAt: start.addingTimeInterval(1000))
        let exactlyAtEnd = makeReceipt(total: 999, currencyCode: "AUD", purchasedAt: end) // must be excluded
        let beforeStart = makeReceipt(total: 999, currencyCode: "AUD", purchasedAt: start.addingTimeInterval(-1))

        repo.receipts = [insideStart, insideMiddle, insideUSD, exactlyAtEnd, beforeStart]

        let totals = try await calculateSpending(from: start, to: end)
        #expect(totals["AUD"] == 100)
        #expect(totals["USD"] == 25)

        // Validation rule: start >= end throws invalidDateRange
        await #expect(throws: FolioError.invalidDateRange) {
            try await calculateSpending(from: start, to: start)
        }
        await #expect(throws: FolioError.invalidDateRange) {
            try await calculateSpending(from: end, to: start)
        }
    }

    @Test("CreateReturnReminder enforces receipt existence, return policy, and deadline boundaries")
    func testCreateReturnReminderValidation() async throws {
        let receiptsRepo = MockReceiptRepository()
        let remindersRepo = MockReminderRepository()
        let receipt = makeReceipt(returnWindowDays: 14)
        receiptsRepo.receipts = [receipt]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let createReminder = CreateReturnReminder(
            receipts: receiptsRepo,
            reminders: remindersRepo,
            calendar: calendar,
            now: { self.testDate }
        )

        // 1. Happy path: within window
        let validNotify = testDate.addingTimeInterval(5 * 86400)
        let reminder = try await createReminder(receiptID: receipt.id, notifyAt: validNotify)
        #expect(reminder.receiptID == receipt.id)
        #expect(reminder.notifyAt == validNotify)
        #expect(remindersRepo.reminders.count == 1)

        // 2. Receipt not found
        await #expect(throws: FolioError.receiptNotFound) {
            try await createReminder(receiptID: UUID(), notifyAt: validNotify)
        }

        // 3. Receipt has no return policy
        let noPolicyReceipt = makeReceipt(returnWindowDays: nil)
        receiptsRepo.receipts.append(noPolicyReceipt)
        await #expect(throws: FolioError.invalidReturnPolicy) {
            try await createReminder(receiptID: noPolicyReceipt.id, notifyAt: validNotify)
        }

        // 4. notifyAt is now or in the past
        await #expect(throws: FolioError.invalidReminderDate) {
            try await createReminder(receiptID: receipt.id, notifyAt: self.testDate)
        }
        await #expect(throws: FolioError.invalidReminderDate) {
            try await createReminder(receiptID: receipt.id, notifyAt: self.testDate.addingTimeInterval(-60))
        }

        // 5. notifyAt is strictly after return deadline
        let deadline = calendar.date(byAdding: .day, value: 14, to: receipt.purchasedAt)!
        await #expect(throws: FolioError.invalidReminderDate) {
            try await createReminder(receiptID: receipt.id, notifyAt: deadline.addingTimeInterval(1))
        }
    }

    // MARK: - 2. Company Domain Use Cases & Business Validation

    @Test("ConfirmCompany validates unique match, merges aliases on single match, and rejects ambiguous/empty input")
    func testConfirmCompanyRules() async throws {
        let repo = MockCompanyRepository()
        let confirmCompany = ConfirmCompany(repository: repo)

        // 1. Reject empty or whitespace-only name
        await #expect(throws: FolioError.invalidReceipt) {
            try await confirmCompany(Company(name: "   "))
        }

        // 2. Zero matches -> creates confirmed company
        let newCo = Company(name: "Bunnings", aliases: ["Bunnings Warehouse"], domain: "bunnings.com.au")
        let confirmed = try await confirmCompany(newCo)
        #expect(confirmed.confirmed == true)
        #expect(repo.companies.count == 1)

        // 3. Exactly one match -> merges aliases and updates
        let duplicateProposal = Company(name: "Bunnings Trade", aliases: ["Bunnings Commercial"], domain: "bunnings.com.au")
        let merged = try await confirmCompany(duplicateProposal)
        #expect(merged.id == confirmed.id)
        #expect(merged.aliases.contains("Bunnings Trade"))
        #expect(merged.aliases.contains("Bunnings Commercial"))

        // 4. Multiple matches (> 1) -> throws invalidReceipt
        let coA = Company(name: "Target Australia", aliases: ["Target"], confirmed: true)
        let coB = Company(name: "Target US", aliases: ["Target"], confirmed: true)
        repo.companies = [coA, coB]
        await #expect(throws: FolioError.invalidReceipt) {
            try await confirmCompany(Company(name: "Target"))
        }
    }

    @Test("AssociateReceiptCompany requires confirmed company status")
    func testAssociateReceiptCompanyValidation() throws {
        let associate = AssociateReceiptCompany()
        let receipt = makeReceipt(retailer: "Draft")
        let confirmedCompany = Company(id: UUID(), name: "Nike Official", confirmed: true)
        let unconfirmedCompany = Company(id: UUID(), name: "Nike Unconfirmed", confirmed: false)

        // Confirmed company links successfully
        let linked = try associate(receipt, company: confirmedCompany)
        #expect(linked.retailer.name == "Nike Official")
        #expect(linked.retailer.companyID == confirmedCompany.id)

        // Unconfirmed company rejected
        #expect(throws: FolioError.invalidReceipt) {
            try associate(receipt, company: unconfirmedCompany)
        }
    }

    @Test("SearchCompanyPurchases queries across retailer, item names, and company aliases case-insensitively")
    func testSearchCompanyPurchasesMatching() async throws {
        let receiptsRepo = MockReceiptRepository()
        let companyRepo = MockCompanyRepository()
        let search = SearchCompanyPurchases(receipts: receiptsRepo, companies: companyRepo)

        let comp = Company(id: UUID(), name: "Apple", aliases: ["Cupertino"], confirmed: true)
        companyRepo.companies = [comp]

        let r1 = makeReceipt(retailer: "Apple Store", items: [PurchasedItem(name: "MacBook Pro", quantity: 1, unitPrice: 2000)])
        let r2 = makeReceipt(retailer: "General Store", items: [PurchasedItem(name: "iPad Air", quantity: 1, unitPrice: 800)])
        let r3 = makeReceipt(retailer: "Cupertino Outlet", items: [PurchasedItem(name: "Cable", quantity: 1, unitPrice: 30)])
        let r4 = makeReceipt(retailer: "Unrelated Store", items: [PurchasedItem(name: "Shoes", quantity: 1, unitPrice: 50)])

        receiptsRepo.receipts = [r1, r2, r3, r4]

        // Match by item
        let itemMatches = try await search("ipad")
        #expect(itemMatches.count == 1)
        #expect(itemMatches.first?.id == r2.id)

        // Match by company alias
        let aliasMatches = try await search("cupertino")
        #expect(aliasMatches.contains { $0.id == r3.id })

        // Empty search returns all receipts
        let all = try await search("   ")
        #expect(all.count == 4)
    }

    // MARK: - 3. Receipt Library Domain Use Cases & Business Validation

    @Test("SearchReceipts and DetectDuplicateReceipt query repository correctly")
    func testSearchAndDuplicateReceipts() async throws {
        let repo = MockReceiptLibraryRepository()
        let searchReceipts = SearchReceipts(repository: repo)
        let detectDuplicates = DetectDuplicateReceipt(repository: repo)

        let receipt = makeReceipt()
        let record = ReceiptRecord(receipt: receipt)
        repo.records[receipt.id] = record
        repo.duplicatesToReturn = [record]

        let filter = ReceiptFilter(searchText: "Acme", profile: .personal)
        let searchResults = try await searchReceipts(filter)
        #expect(searchResults.count == 1)

        let duplicates = try await detectDuplicates(receipt)
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.id == receipt.id)
    }

    @Test("AttachReceiptDetails validates receipt existence and updates images, costs, and source")
    func testAttachReceiptDetailsValidation() async throws {
        let repo = MockReceiptLibraryRepository()
        let imageStore = MockReceiptImageStore()
        let attach = AttachReceiptDetails(repository: repo, images: imageStore)

        let receipt = makeReceipt()
        let record = ReceiptRecord(receipt: receipt)
        repo.records[receipt.id] = record

        let pageData = [Data("page1".utf8), Data("page2".utf8)]
        let breakdown = ReceiptCostBreakdown(subtotal: 90, fees: 10, total: 100)

        try await attach(
            receiptID: receipt.id,
            costs: breakdown,
            source: .foundationModels,
            pages: pageData
        )

        let updated = repo.records[receipt.id]
        #expect(updated?.metadata.imageCount == 2)
        #expect(updated?.costs?.total == 100)
        #expect(updated?.metadata.extractionSource == .foundationModels)
        #expect(imageStore.storedPages[receipt.id]?.count == 2)

        // Non-existent receipt throws receiptNotFound
        await #expect(throws: FolioError.receiptNotFound) {
            try await attach(receiptID: UUID(), costs: breakdown, source: .foundationModels, pages: pageData)
        }
    }

    @Test("UpdateReceiptMetadata normalizes tags, trims category whitespace, and rejects missing receipt")
    func testUpdateReceiptMetadataValidation() async throws {
        let repo = MockReceiptLibraryRepository()
        let updateMetadata = UpdateReceiptMetadata(repository: repo)

        let receipt = makeReceipt()
        let record = ReceiptRecord(receipt: receipt)
        repo.records[receipt.id] = record

        // Tags to normalize: whitespace, case-insensitive duplicates, empty entries
        let tags = ["  Tax  ", "tax", "TAX", "", "  ", "Electronics", "electronics"]
        try await updateMetadata(id: receipt.id) { metadata in
            metadata.category = "  Home Office  "
            metadata.tags = tags
            metadata.notes = "Updated note"
        }

        let updated = repo.records[receipt.id]
        #expect(updated?.metadata.category == "Home Office")
        #expect(updated?.metadata.tags == ["Tax", "Electronics"])
        #expect(updated?.metadata.notes == "Updated note")

        // Non-existent receipt throws receiptNotFound
        await #expect(throws: FolioError.receiptNotFound) {
            try await updateMetadata(id: UUID()) { metadata in
                metadata.category = "Cat"
            }
        }
    }

    @Test("ManageRetailers validates non-empty names, uniqueness, policy thresholds, and supports deletion")
    func testManageRetailersValidation() async throws {
        let repo = MockRetailerRepository()
        let manage = ManageRetailers(repository: repo)

        // 1. Reject empty name
        let emptyNameRetailer = SavedRetailer(name: "   ", policies: [SavedPolicy(kind: .returns, title: "Return", windowDays: 30)])
        await #expect(throws: RetailerError.emptyName) {
            try await manage.save(emptyNameRetailer)
        }

        // 2. Reject policy with empty title
        let emptyPolicyTitle = SavedRetailer(name: "Zara", policies: [SavedPolicy(kind: .returns, title: "", windowDays: 30)])
        await #expect(throws: RetailerError.invalidPolicy) {
            try await manage.save(emptyPolicyTitle)
        }

        // 3. Reject policy with invalid windowDays (not in 1...3650)
        let zeroWindow = SavedRetailer(name: "Zara", policies: [SavedPolicy(kind: .returns, title: "Return", windowDays: 0)])
        let excessiveWindow = SavedRetailer(name: "Zara", policies: [SavedPolicy(kind: .returns, title: "Return", windowDays: 4000)])
        await #expect(throws: RetailerError.invalidPolicy) { try await manage.save(zeroWindow) }
        await #expect(throws: RetailerError.invalidPolicy) { try await manage.save(excessiveWindow) }

        // 4. Valid save
        let validRetailer = SavedRetailer(name: "Zara", policies: [SavedPolicy(kind: .returns, title: "Standard Return", windowDays: 30)])
        try await manage.save(validRetailer)
        #expect(repo.retailers.count == 1)

        // 5. Reject duplicate name with different id
        let duplicateName = SavedRetailer(id: UUID(), name: "  zara  ", policies: [SavedPolicy(kind: .returns, title: "Return", windowDays: 14)])
        await #expect(throws: RetailerError.duplicateName("zara")) {
            try await manage.save(duplicateName)
        }

        // 6. Editing existing retailer with same name is allowed
        var updatedZara = validRetailer
        updatedZara.policies.append(SavedPolicy(kind: .warranty, title: "Extended Warranty", windowDays: 365))
        try await manage.save(updatedZara)
        #expect(repo.retailers[validRetailer.id]?.policies.count == 2)

        // 7. Delete retailer
        try await manage.delete(id: validRetailer.id)
        #expect(repo.retailers.isEmpty)
    }

    @Test("DeleteReceipt cascades to associated reminders, notifications, and stored images")
    func testDeleteReceiptCascades() async throws {
        let libraryRepo = MockReceiptLibraryRepository()
        let reminderRepo = MockReminderRepository()
        let scheduler = MockReminderScheduler()
        let imageStore = MockReceiptImageStore()

        let deleteReceipt = DeleteReceipt(
            repository: libraryRepo,
            images: imageStore,
            reminders: reminderRepo,
            scheduler: scheduler
        )

        let receipt = makeReceipt()
        libraryRepo.records[receipt.id] = ReceiptRecord(receipt: receipt)
        try _ = imageStore.save([Data("image".utf8)], for: receipt.id)

        let r1 = ReturnReminder(receiptID: receipt.id, deadline: testDate, notifyAt: testDate)
        let r2 = ReturnReminder(receiptID: receipt.id, deadline: testDate, notifyAt: testDate)
        let unrelated = ReturnReminder(receiptID: UUID(), deadline: testDate, notifyAt: testDate)
        reminderRepo.reminders = [r1, r2, unrelated]

        try await deleteReceipt(id: receipt.id)

        #expect(libraryRepo.records[receipt.id] == nil)
        #expect(reminderRepo.reminders.count == 1)
        #expect(reminderRepo.reminders.first?.id == unrelated.id)
        #expect(scheduler.cancelled.contains(r1.id))
        #expect(scheduler.cancelled.contains(r2.id))
        #expect(imageStore.storedPages[receipt.id] == nil)
    }

    // MARK: - 4. Return Reminders Domain Use Cases & Business Validation

    @Test("DetermineReminderStatus computes expired, dueSoon, and upcoming thresholds")
    func testDetermineReminderStatusThresholds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let determine = DetermineReminderStatus(calendar: calendar, now: { self.testDate })

        func makeReminder(daysFromNow days: Int) -> ReturnReminder {
            let deadline = calendar.date(byAdding: .day, value: days, to: self.testDate)!
            return ReturnReminder(receiptID: UUID(), deadline: deadline, notifyAt: self.testDate)
        }

        // Expired: negative days
        #expect(determine(makeReminder(daysFromNow: -1)) == .expired)
        #expect(determine(makeReminder(daysFromNow: -5)) == .expired)

        // Due soon: 0...3 days
        #expect(determine(makeReminder(daysFromNow: 0)) == .dueSoon(daysRemaining: 0))
        #expect(determine(makeReminder(daysFromNow: 1)) == .dueSoon(daysRemaining: 1))
        #expect(determine(makeReminder(daysFromNow: 3)) == .dueSoon(daysRemaining: 3))

        // Upcoming: > 3 days
        #expect(determine(makeReminder(daysFromNow: 4)) == .upcoming(daysRemaining: 4))
        #expect(determine(makeReminder(daysFromNow: 30)) == .upcoming(daysRemaining: 30))
    }

    @Test("LoadReminderSummaries joins reminders with receipts, handles missing receipts, and sorts by deadline")
    func testLoadReminderSummariesRules() async throws {
        let receiptsRepo = MockReceiptRepository()
        let remindersRepo = MockReminderRepository()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let loadSummaries = LoadReminderSummaries(
            reminders: remindersRepo,
            receipts: receiptsRepo,
            determineStatus: DetermineReminderStatus(calendar: calendar, now: { self.testDate })
        )

        let receipt = makeReceipt(retailer: "Apple Store")
        receiptsRepo.receipts = [receipt]

        let earlyDeadline = testDate.addingTimeInterval(2 * 86400)
        let lateDeadline = testDate.addingTimeInterval(10 * 86400)

        // Reminder 1 matches existing receipt
        let rem1 = ReturnReminder(receiptID: receipt.id, deadline: lateDeadline, notifyAt: testDate)
        // Reminder 2 has missing receipt -> fallback to "Unknown retailer"
        let rem2 = ReturnReminder(receiptID: UUID(), deadline: earlyDeadline, notifyAt: testDate)

        remindersRepo.reminders = [rem1, rem2]

        let summaries = try await loadSummaries()
        #expect(summaries.count == 2)
        // Earliest deadline first
        #expect(summaries[0].id == rem2.id)
        #expect(summaries[0].retailerName == "Unknown retailer")
        #expect(summaries[1].id == rem1.id)
        #expect(summaries[1].retailerName == "Apple Store")
    }

    @Test("DeleteReturnReminder deletes reminder and cancels notification")
    func testDeleteReturnReminderRules() async throws {
        let remindersRepo = MockReminderRepository()
        let scheduler = MockReminderScheduler()
        let deleteReminder = DeleteReturnReminder(reminders: remindersRepo, scheduler: scheduler)

        let reminder = ReturnReminder(receiptID: UUID(), deadline: testDate, notifyAt: testDate)
        remindersRepo.reminders = [reminder]

        try await deleteReminder(id: reminder.id)
        #expect(remindersRepo.reminders.isEmpty)
        #expect(scheduler.cancelled.contains(reminder.id))
    }

    // MARK: - 5. Repository Error Mapping Using Mock Data Layer

    @Test("Repository persistence errors are mapped and propagated reliably across domain use cases")
    func testRepositoryErrorMappingAcrossUseCases() async {
        let receiptsRepo = MockReceiptRepository()
        let remindersRepo = MockReminderRepository()
        let companyRepo = MockCompanyRepository()
        let libraryRepo = MockReceiptLibraryRepository()
        let retailerRepo = MockRetailerRepository()
        let imageStore = MockReceiptImageStore()
        let scheduler = MockReminderScheduler()

        // 1. SaveReceipt maps repository failure
        receiptsRepo.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await SaveReceipt(repository: receiptsRepo)(makeReceipt())
        }

        // 2. FetchReceipts maps repository failure
        await #expect(throws: FolioError.persistenceFailure) {
            try await FetchReceipts(repository: receiptsRepo)()
        }

        // 3. CalculateSpending maps repository failure
        await #expect(throws: FolioError.persistenceFailure) {
            try await CalculateSpending(repository: receiptsRepo)(from: testDate, to: testDate.addingTimeInterval(3600))
        }

        // 4. CreateReturnReminder maps receipt/reminder repository failure
        receiptsRepo.shouldThrowError = nil
        let sampleReceipt = makeReceipt()
        receiptsRepo.receipts = [sampleReceipt]
        remindersRepo.shouldThrowError = FolioError.persistenceFailure
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let createReminder = CreateReturnReminder(receipts: receiptsRepo, reminders: remindersRepo, calendar: calendar, now: { self.testDate })
        await #expect(throws: FolioError.persistenceFailure) {
            try await createReminder(receiptID: sampleReceipt.id, notifyAt: self.testDate.addingTimeInterval(86400))
        }

        // 5. ConfirmCompany maps repository failure
        companyRepo.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await ConfirmCompany(repository: companyRepo)(Company(name: "Test Co"))
        }

        // 6. SearchReceipts & DetectDuplicateReceipt map library repository failure
        libraryRepo.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await SearchReceipts(repository: libraryRepo)(ReceiptFilter())
        }
        await #expect(throws: FolioError.persistenceFailure) {
            try await DetectDuplicateReceipt(repository: libraryRepo)(sampleReceipt)
        }

        // 7. AttachReceiptDetails maps image store and library repository failures
        libraryRepo.shouldThrowError = nil
        libraryRepo.records[sampleReceipt.id] = ReceiptRecord(receipt: sampleReceipt)
        imageStore.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await AttachReceiptDetails(repository: libraryRepo, images: imageStore)(
                receiptID: sampleReceipt.id, costs: ReceiptCostBreakdown(total: 10), source: .vision, pages: [Data("data".utf8)]
            )
        }

        // 8. ManageRetailers maps repository failure
        retailerRepo.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await ManageRetailers(repository: retailerRepo).all()
        }
        await #expect(throws: RetailerError.emptyName) {
            try await ManageRetailers(repository: retailerRepo).save(SavedRetailer(name: "   "))
        }
        await #expect(throws: FolioError.persistenceFailure) {
            try await ManageRetailers(repository: retailerRepo).save(SavedRetailer(name: "Valid Retailer"))
        }

        // 9. Cascading DeleteReceipt failure: if reminder deletion fails, library record and image are preserved
        imageStore.shouldThrowError = nil
        remindersRepo.reminders = [ReturnReminder(receiptID: sampleReceipt.id, deadline: testDate, notifyAt: testDate)]
        remindersRepo.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await DeleteReceipt(repository: libraryRepo, images: imageStore, reminders: remindersRepo, scheduler: scheduler)(id: sampleReceipt.id)
        }
        #expect(libraryRepo.records[sampleReceipt.id] != nil) // Preserved!

        // 10. DeleteReturnReminder failure does NOT cancel notification
        scheduler.cancelled.removeAll()
        remindersRepo.shouldThrowError = FolioError.persistenceFailure
        await #expect(throws: FolioError.persistenceFailure) {
            try await DeleteReturnReminder(reminders: remindersRepo, scheduler: scheduler)(id: UUID())
        }
        #expect(scheduler.cancelled.isEmpty)
    }

    @Test("SwiftData repositories map corrupt payloads and schema decoding errors to FolioError.persistenceFailure")
    func testSwiftDataRepositoryErrorMapping() async throws {
        let schema = Schema([StoredReceipt.self, StoredReminder.self, StoredRetailer.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        // 1. Corrupt StoredReceipt payload maps to persistenceFailure
        context.insert(StoredReceipt(id: UUID(), payload: Data("corrupt payload".utf8)))
        try context.save()
        let receiptRepo = SwiftDataReceiptRepository(container: container)
        await #expect(throws: FolioError.persistenceFailure) {
            try await receiptRepo.fetchAll()
        }

        // 2. Corrupt StoredReminder schema maps to persistenceFailure
        let reminder = StoredReminder(id: UUID(), payload: Data("{}".utf8))
        reminder.schemaVersion = 999 // Unsupported schema
        context.insert(reminder)
        try context.save()
        let reminderRepo = SwiftDataReminderRepository(container: container)
        await #expect(throws: FolioError.persistenceFailure) {
            try await reminderRepo.fetchAll()
        }

        // 3. Corrupt StoredRetailer schema maps to persistenceFailure
        let retailer = StoredRetailer(id: UUID(), name: "Bad", nameKey: "bad", payload: Data("{}".utf8))
        retailer.schemaVersion = 999 // Unsupported schema
        context.insert(retailer)
        try context.save()
        let retailerRepo = SwiftDataRetailerRepository(container: container)
        await #expect(throws: FolioError.persistenceFailure) {
            try await retailerRepo.fetchAll()
        }
    }
}
