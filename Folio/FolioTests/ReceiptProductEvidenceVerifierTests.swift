import Foundation
import Testing
@testable import Folio

struct ReceiptProductEvidenceVerifierTests {
    private func propose(
        _ name: String,
        at line: Int,
        price: String?,
        quantity: String? = nil
    ) -> FocusedReceiptProductProposal {
        .init(sourceLine: line, name: name, quantity: quantity,
              lineTotal: price, evidence: name)
    }

    private func empty() -> ReceiptExtractionMapper.Mapped {
        .init(costs: ReceiptCostBreakdown(), anchoredProducts: [], warnings: [])
    }

    @Test func printedCommaPricesAndQuantitiesAreKept() {
        let lines = ["STARTERS", "Garlic Bread x2   € 7,30", "Crispy Calamari   € 6,50"]
        let found = ReceiptProductEvidenceVerifier.verify([
            propose("Garlic Bread", at: 2, price: "7,30", quantity: "2"),
            propose("Crispy Calamari", at: 3, price: "6,50")
        ], lines: lines, startLine: 1)
        #expect(found.count == 2)
        #expect(found[0].product.lineTotal == Decimal(string: "7.30"))
        #expect(found[0].product.quantity == Decimal(2))
        #expect(found[1].product.lineTotal == Decimal(string: "6.50"))
    }

    @Test func correctPriceCanBeRecoveredFromWrappedItem() {
        let found = ReceiptProductEvidenceVerifier.verify([
            propose("Pan-Seared Salmon w/ New Potatoes", at: 1, price: "17,90")
        ], lines: ["Pan-Seared Salmon w/", "New Potatoes £17,90"], startLine: 1)
        #expect(found.count == 1)
        #expect(found.first?.product.lineTotal == Decimal(string: "17.90"))
    }

    @Test func nextProductsPriceAndUnsupportedAmountsAreRejected() {
        let borrowed = ReceiptProductEvidenceVerifier.verify([
            propose("Pan-Seared Salmon", at: 1, price: "21,50")
        ], lines: ["Pan-Seared Salmon w/", "Ribeye Steak £21,50"], startLine: 1)
        #expect(borrowed.isEmpty)

        let unsupported = ReceiptProductEvidenceVerifier.verify([
            propose("Ribeye Steak", at: 1, price: "20,50"),
            propose("TOTAL", at: 2, price: "79,44")
        ], lines: ["Ribeye Steak £21,50", "Total £79,44"], startLine: 1)
        #expect(unsupported.isEmpty)
    }

    @Test func partialRecoveryDoesNotRequireReceiptTotalsToReconcile() {
        let verified = ReceiptProductEvidenceVerifier.verify([
            propose("Garlic Bread", at: 1, price: "7,30"),
            propose("Salmon", at: 2, price: "17,90")
        ], lines: ["Garlic Bread £7,30", "Salmon £17,90"], startLine: 1)
        let merged = ReceiptProductEvidenceVerifier.merge(verified, into: empty())
        #expect(merged.costs.products.count == 2)
        #expect(merged.costs.products.first?.lineTotal == Decimal(string: "7.30"))
        #expect(merged.costs.total == nil)
    }

    @Test func existingVerifiedLinePriceMustNotBeOverwritten() {
        let originalItem = ReceiptCostBreakdown.Product(
            name: "Garlic Bread", lineTotal: Decimal(string: "7.80"))
        let original = ReceiptExtractionMapper.Mapped(
            costs: ReceiptCostBreakdown(products: [originalItem]),
            anchoredProducts: [(line: 5, product: originalItem)],
            warnings: []
        )
        let verified = ReceiptProductEvidenceVerifier.verify([
            propose("Garlic Bread", at: 5, price: "7,30")
        ], lines: ["Garlic Bread £7,30"], startLine: 5)
        let merged = ReceiptProductEvidenceVerifier.merge(verified, into: original)
        #expect(merged.costs.products.count == 1)
        #expect(merged.costs.products[0].lineTotal == Decimal(string: "7.80"))
    }

    @Test func missingPriceFilledWithoutChangingTotal() {
        let originalItem = ReceiptCostBreakdown.Product(name: "Salmon", lineTotal: nil)
        var costs = ReceiptCostBreakdown(products: [originalItem])
        costs.total = Decimal(string: "79.44")
        let original = ReceiptExtractionMapper.Mapped(
            costs: costs,
            anchoredProducts: [(line: 10, product: originalItem)], warnings: []
        )
        let verified = ReceiptProductEvidenceVerifier.verify([
            propose("Salmon", at: 10, price: "17,90")
        ], lines: ["Salmon £17,90"], startLine: 10)
        let merged = ReceiptProductEvidenceVerifier.merge(verified, into: original)
        #expect(merged.costs.products[0].lineTotal == Decimal(string: "17.90"))
        #expect(merged.costs.total == Decimal(string: "79.44"))
    }
}
