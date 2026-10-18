import Foundation

/// Pure business rules. Warnings never rewrite OCR or a printed/user-entered total.
enum ReceiptCostValidator {
    static func warnings(for draft: ReceiptReviewDraft) -> [String] {
        var warnings: [String] = []
        func check(_ text: String, _ label: String, allowNegative: Bool = false) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let amount = ReceiptAmountParser.parse(text) else {
                warnings.append("\(label): enter a number using a decimal point (no currency symbols).")
                return
            }
            if !allowNegative && amount < 0 { warnings.append("\(label) cannot be negative.") }
        }
        let costs = draft.costs
        if costs.products.isEmpty { warnings.append("No products identified. Add each purchased product or review the original receipt.") }
        for (index, item) in draft.products.enumerated() {
            let label = "Product \(index + 1)"
            if item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("\(label) needs a name.") }
            check(item.quantity, "\(label) quantity")
            check(item.unitPrice, "\(label) unit price")
            check(item.lineTotal, "\(label) line cost", allowNegative: true)
            check(item.discount, "\(label) discount")
            let product = costs.products[index]
            if let quantity = product.quantity, quantity <= 0 { warnings.append("\(label) quantity must be greater than zero.") }
            if product.lineTotal == nil { warnings.append("\(label) has a missing or unreadable line cost.") }
            if let total = product.lineTotal, (total < 0) != product.isReturn, total != 0 {
                warnings.append("\(label): confirm the return flag and signed line cost.")
            }
            if let quantity = product.quantity, let unit = product.unitPrice, let line = product.lineTotal {
                let expected = (quantity * unit - (product.discount ?? 0)) * (product.isReturn ? -1 : 1)
                if abs(expected - line) > Decimal(string: "0.01")! {
                    warnings.append("\(label): quantity × unit price, less its discount, does not match the line cost. Check offers or rounding.")
                }
            }
        }
        check(draft.subtotal, "Subtotal", allowNegative: true)
        check(draft.discounts, "Discounts")
        check(draft.tax, "GST / tax", allowNegative: true)
        check(draft.fees, "Additional fees", allowNegative: true)
        check(draft.rounding, "Rounding", allowNegative: true)
        check(draft.total, "Final total", allowNegative: true)
        guard let total = costs.total else {
            warnings.append("Final total is missing or unreadable. Enter the printed total; it will not be inferred from products.")
            return warnings
        }
        if costs.tax != nil && costs.tax != 0 && costs.taxTreatment == .unknown {
            warnings.append("Confirm whether GST / tax is already included before reconciling the total.")
        }
        if costs.discounts != nil && costs.discounts != 0 && costs.discountTreatment == .unknown {
            warnings.append("Confirm whether discounts are already included in line costs before reconciling the total.")
        }
        // Do not present a numeric reconciliation when any edit is invalid or treatment is unknown.
        guard warnings.isEmpty, !costs.products.isEmpty,
              costs.products.allSatisfy({ $0.lineTotal != nil }) else {
            warnings.append("Total cannot be fully reconciled until the flagged fields are reviewed.")
            return warnings
        }
        let sum = costs.products.reduce(Decimal.zero) { $0 + ($1.lineTotal ?? 0) }
        let discount = costs.discountTreatment == .deductedFromLines ? (costs.discounts ?? 0) : 0
        let tax = costs.taxTreatment == .added ? (costs.tax ?? 0) : 0
        let expected = sum - discount + tax + (costs.fees ?? 0) + (costs.rounding ?? 0)
        if abs(expected - total) > Decimal(string: "0.01")! {
            warnings.append("Product costs and entered adjustments differ from the final total by \(ReceiptAmountParser.text(abs(expected - total))). Check missing products, discounts, fees, tax and rounding. The final total has been kept unchanged.")
        }
        // Subtotal can be printed before or after receipt-level discounts; accept either convention.
        if let subtotal = costs.subtotal,
           abs(subtotal - sum) > Decimal(string: "0.01")!,
           abs(subtotal - (sum - discount)) > Decimal(string: "0.01")! {
            warnings.append("Printed subtotal does not match the product costs before or after the entered discounts. Check the receipt's subtotal convention.")
        }
        return warnings
    }
}
