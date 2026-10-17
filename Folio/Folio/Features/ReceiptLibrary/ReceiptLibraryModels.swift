import Foundation

struct ReceiptRecord: Identifiable, Codable, Equatable, Sendable {
    var receipt: PurchaseReceipt
    var costs: ReceiptCostBreakdown?
    var metadata = ReceiptMetadata()

    var id: UUID { receipt.id }
}

struct ReceiptMetadata: Codable, Equatable, Sendable {
    enum ExtractionSource: String, Codable, Sendable { case vision, foundationModels, manual }

    var category = ""
    var tags: [String] = []
    var notes = ""
    var imageCount = 0
    var extractionSource: ExtractionSource?
    var createdAt = Date()
    var updatedAt = Date()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        imageCount = try c.decodeIfPresent(Int.self, forKey: .imageCount) ?? 0
        extractionSource = try? c.decodeIfPresent(ExtractionSource.self, forKey: .extractionSource)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

@MainActor protocol ReceiptLibraryRepository {
    func save(_ record: ReceiptRecord) async throws
    func fetchRecord(id: UUID) async throws -> ReceiptRecord?
    func search(_ filter: ReceiptFilter) async throws -> [ReceiptRecord]
    func delete(id: UUID) async throws
    func possibleDuplicates(of receipt: PurchaseReceipt) async throws -> [ReceiptRecord]
}

struct ReceiptFilter: Equatable, Sendable {
    enum Sort: Equatable, Sendable {
        case dateDescending, dateAscending
        case totalDescending, totalAscending
        case retailerAscending
    }

    var searchText = ""
    var dateRange: Range<Date>?
    var profile: PurchaseProfile?
    var retailerName: String?
    var category: String?
    var tag: String?
    var currencyCode: String?
    var minTotal: Decimal?
    var maxTotal: Decimal?
    var sort: Sort = .dateDescending

    static let all = ReceiptFilter()
}

enum ReceiptFingerprint {
    static func make(for receipt: PurchaseReceipt) -> String {
        make(retailer: receipt.retailer.name, date: receipt.purchasedAt,
             totalMinorUnits: minorUnits(receipt.total), currencyCode: receipt.currencyCode)
    }

    static func make(retailer: String, date: Date, totalMinorUnits: Int, currencyCode: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let dayKey = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let name = retailer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [name, dayKey, String(totalMinorUnits), currencyCode.uppercased()].joined(separator: "|")
    }

    static func minorUnits(_ value: Decimal) -> Int {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
