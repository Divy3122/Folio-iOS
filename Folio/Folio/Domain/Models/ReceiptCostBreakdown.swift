import Foundation

/// Unverified extraction/review data, not a saved PurchaseReceipt. Missing is distinct from zero.
/// This additive contract supports partial OCR without weakening validated purchase models.
struct ReceiptCostBreakdown: Codable, Equatable, Sendable {
    struct Product: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var name: String
        var quantity: Decimal?
        var unitPrice: Decimal?
        var lineTotal: Decimal?
        var discount: Decimal?
        var isReturn = false
    }

    enum TaxTreatment: String, Codable, CaseIterable, Sendable {
        case included, added, unknown
    }
    enum DiscountTreatment: String, Codable, CaseIterable, Sendable {
        case includedInLines, deductedFromLines, unknown
    }

    var products: [Product] = []
    var subtotal: Decimal?
    var discounts: Decimal?
    var tax: Decimal?
    var fees: Decimal?
    var rounding: Decimal?
    var total: Decimal?
    var taxTreatment: TaxTreatment = .unknown
    var discountTreatment: DiscountTreatment = .unknown
}
