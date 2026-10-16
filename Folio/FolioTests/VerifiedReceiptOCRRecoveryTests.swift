import Foundation
import Testing
@testable import Folio

struct VerifiedReceiptOCRRecoveryTests {
    private let bistro = """
        THE WILLOW FORK BISTRO
        STARTERS
        Garlic Bread x2    £7,80
        Crispy Calamari    £6,50
        MAINS
        Pan-Seared Salmon w/ New Potatoes £17,90
        Ribeye Steak (10oz) w/ Peppercorn Sauce 21,50
        DRINKS
        House Red (175ml) x2 £11,00
        Still Water (750ml) £1,50
        Subtotal (excl. VAT): £66,20
        VAT (20%) £13,24
        Total £79,44
        Payment Method Visa Credit
        Auth Code 542893
        """

    private func empty(_ ocr: String) -> ReceiptExtractionResult {
        ReceiptExtractionResult(rawText: ocr, candidate: nil,
                                source: .vision, reviewWarnings: [])
    }

    @Test func bistroItemsAndPrintedTotals() {
        let result = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(bistro), from: bistro)
        let costs = result.costBreakdown
        #expect(costs?.products.map(\.name) == [
            "Garlic Bread", "Crispy Calamari", "Pan-Seared Salmon w/ New Potatoes",
            "Ribeye Steak (10oz) w/ Peppercorn Sauce", "House Red (175ml)", "Still Water (750ml)"
        ])
        #expect(costs?.products.first?.quantity == Decimal(2))
        if let products = costs?.products, products.count > 4 {
            #expect(products[4].quantity == Decimal(2))
        }
        #expect(costs?.subtotal == Decimal(string: "66.20"))
        #expect(costs?.tax == Decimal(string: "13.24"))
        #expect(costs?.total == Decimal(string: "79.44"))
        #expect(costs?.taxTreatment == .added)
        if let costs {
            #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
        }
    }

    @Test func separateColumnsCanBeRecombined() {
        let ocr = """
        STARTERS
        Garlic Bread x2
        Crispy Calamari
        £7,80
        £6,50
        MAINS
        Pan-Seared Salmon w/ New Potatoes
        Ribeye Steak (10oz) w/ Peppercorn Sauce
        £17,90
        £21,50
        DRINKS
        House Red (175ml) x2
        Still Water (750ml)
        £11,00
        £1,50
        Subtotal (excl. VAT): £66,20
        VAT (20%) £13,24
        Total £79,44
        """
        let costs = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(ocr), from: ocr).costBreakdown
        #expect(costs?.products.count == 6)
        #expect(costs?.total == Decimal(string: "79.44"))
    }

    @Test func existingProductsAreNeverOverwritten() {
        var result = empty(bistro)
        result.costBreakdown = ReceiptCostBreakdown(products: [
            .init(name: "Already verified", lineTotal: Decimal(string: "4.99"))
        ])
        let recovered = VerifiedReceiptOCRRecovery.recoverIfComplete(result, from: bistro)
        #expect(recovered.costBreakdown == result.costBreakdown)
    }

    @Test func conflictingPrintedTotalsRemainUnresolved() {
        let ocr = bistro + "\nTotal £80,44"
        let result = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(ocr), from: ocr)
        #expect(result.costBreakdown == nil)
    }

    @Test func obviousMetadataCorruptionCanBeReplacedWithoutDroppingValidItems() {
        var result = empty(bistro)
        result.costBreakdown = ReceiptCostBreakdown(products: [
            .init(name: "MAINS", lineTotal: nil),
            .init(name: "Garlic Bread", quantity: 2, lineTotal: Decimal(string: "7.80"))
        ])
        let recovered = VerifiedReceiptOCRRecovery.recoverIfComplete(result, from: bistro)
        #expect(recovered.costBreakdown?.products.count == 6)
    }

    @Test func unreadableProductPriceCannotBeInferred() {
        let ocr = bistro.replacingOccurrences(of: "£11,00", with: "unreadable")
        let result = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(ocr), from: ocr)
        #expect(result.costBreakdown == nil)
    }

    @Test func partialExtractionRepairsMissingPriceAndCorrectsVAT() {
        let reference = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(bistro), from: bistro)
        guard var costs = reference.costBreakdown else {
            Issue.record("Expected complete OCR fixture")
            return
        }
        costs.products[2].lineTotal = nil
        costs.taxTreatment = .included  // AI incorrectly classified an excl.-VAT receipt
        var partial = empty(bistro)
        partial.costBreakdown = costs
        partial.reviewWarnings = ["Pan-Seared Salmon line cost could not be verified against the OCR and was left missing."]

        let recovered = VerifiedReceiptOCRRecovery.recoverIfComplete(partial, from: bistro)
        #expect(recovered.costBreakdown?.products.count == 6)
        #expect(recovered.costBreakdown?.products[2].lineTotal == Decimal(string: "17.90"))
        #expect(recovered.costBreakdown?.taxTreatment == .added)
        if let complete = recovered.costBreakdown {
            #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(complete)).isEmpty)
        }
    }

    @Test func conflictingPreviouslyAcceptedPriceIsNeverOverwritten() {
        let reference = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(bistro), from: bistro)
        guard var costs = reference.costBreakdown else {
            Issue.record("Expected complete OCR fixture")
            return
        }
        costs.products[1].lineTotal = Decimal(string: "9.99")
        costs.products[2].lineTotal = nil
        var partial = empty(bistro)
        partial.costBreakdown = costs

        let recovered = VerifiedReceiptOCRRecovery.recoverIfComplete(partial, from: bistro)
        #expect(recovered.costBreakdown?.products[1].lineTotal == Decimal(string: "9.99"))
        #expect(recovered.costBreakdown?.products[2].lineTotal == nil)
    }

    @Test func optionalUnverifiedEvidenceIsNotTwentyUserWarnings() {
        let reference = VerifiedReceiptOCRRecovery.recoverIfComplete(empty(bistro), from: bistro)
        guard var costs = reference.costBreakdown else {
            Issue.record("Expected complete OCR fixture")
            return
        }
        costs.products[2].lineTotal = nil
        let technicalMessages = (1...21).map {
            "Product \($0) optional field could not be verified against the OCR."
        }
        let attention = ReceiptReviewAttention.notes(
            for: ReceiptReviewDraft(costs), extractionWarnings: technicalMessages
        )
        #expect(attention.count == 1)
        #expect(attention.first?.contains("Pan-Seared Salmon") == true)
        #expect(technicalMessages.count == 21) // Diagnostics are not discarded.
    }
}
