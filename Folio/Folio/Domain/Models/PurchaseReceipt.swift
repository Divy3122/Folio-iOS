import Foundation

struct Retailer: Codable, Equatable, Sendable {
    var name: String
}

struct PurchasedItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var quantity: Int
    var unitPrice: Decimal
}

enum PurchaseProfile: String, Codable, Sendable, CaseIterable {
    case personal, business
}

/// User-confirmed change-of-mind policy; never a statement of statutory rights.
struct ReturnPolicy: Codable, Equatable, Sendable {
    var windowDays: Int
    var notes: String
}

struct PurchaseReceipt: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var retailer: Retailer
    var purchasedAt: Date
    var currencyCode: String
    /// Receipt total is authoritative: tax/discounts can differ from item subtotals.
    var total: Decimal
    var items: [PurchasedItem] = []
    var profile: PurchaseProfile = .personal
    var returnPolicy: ReturnPolicy?
}

struct ReturnReminder: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var receiptID: UUID
    var deadline: Date
    var notifyAt: Date
}

/// Untrusted OCR/AI output must be reviewed before SaveReceipt is called.
struct ReceiptExtractionResult: Sendable {
    enum Source: Sendable { case vision, foundationModels, manual }
    var rawText: String
    var candidate: PurchaseReceipt?
    var source: Source
    var reviewWarnings: [String]
}
