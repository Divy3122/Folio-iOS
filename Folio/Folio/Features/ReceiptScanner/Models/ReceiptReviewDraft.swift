import Foundation

/// Text editing state retains invalid/incomplete input instead of converting it silently to zero.
struct ReceiptReviewDraft: Codable, Equatable, Sendable {
    struct Product: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var name = ""
        var quantity = ""
        var unitPrice = ""
        var lineTotal = ""
        var discount = ""
        var isReturn = false
    }
    var products: [Product] = []
    var subtotal = ""
    var discounts = ""
    var tax = ""
    var fees = ""
    var rounding = ""
    var total = ""
    var taxTreatment: ReceiptCostBreakdown.TaxTreatment = .unknown
    var discountTreatment: ReceiptCostBreakdown.DiscountTreatment = .unknown
    var manualRetailerName: String? = nil
    var manualReceiptDate: Date? = nil

    init(_ costs: ReceiptCostBreakdown = ReceiptCostBreakdown()) {
        products = costs.products.map {
            Product(id: $0.id, name: $0.name, quantity: ReceiptAmountParser.text($0.quantity),
                    unitPrice: ReceiptAmountParser.text($0.unitPrice), lineTotal: ReceiptAmountParser.text($0.lineTotal),
                    discount: ReceiptAmountParser.text($0.discount), isReturn: $0.isReturn)
        }
        subtotal = ReceiptAmountParser.text(costs.subtotal)
        discounts = ReceiptAmountParser.text(costs.discounts)
        tax = ReceiptAmountParser.text(costs.tax)
        fees = ReceiptAmountParser.text(costs.fees)
        rounding = ReceiptAmountParser.text(costs.rounding)
        total = ReceiptAmountParser.text(costs.total)
        taxTreatment = costs.taxTreatment
        discountTreatment = costs.discountTreatment
    }

    var costs: ReceiptCostBreakdown {
        ReceiptCostBreakdown(products: products.map {
            .init(id: $0.id, name: $0.name, quantity: ReceiptAmountParser.parse($0.quantity),
                  unitPrice: ReceiptAmountParser.parse($0.unitPrice), lineTotal: ReceiptAmountParser.parse($0.lineTotal),
                  discount: ReceiptAmountParser.parse($0.discount), isReturn: $0.isReturn)
        }, subtotal: ReceiptAmountParser.parse(subtotal), discounts: ReceiptAmountParser.parse(discounts),
           tax: ReceiptAmountParser.parse(tax), fees: ReceiptAmountParser.parse(fees),
           rounding: ReceiptAmountParser.parse(rounding), total: ReceiptAmountParser.parse(total),
           taxTreatment: taxTreatment, discountTreatment: discountTreatment)
    }
}
