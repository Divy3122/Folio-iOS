import Foundation
import Testing
@testable import Folio

struct ReceiptSemanticTotalVerifierTests {
    private func proposal(
        _ role: ReceiptSemanticAmountProposal.Role,
        _ line: Int,
        _ amount: String
    ) -> ReceiptSemanticAmountProposal {
        .init(role: role, sourceLine: line, printedAmount: amount)
    }

    private func blank(_ text: String = "") -> ReceiptExtractionResult {
        .init(rawText: text, candidate: nil, source: .foundationModels,
              reviewWarnings: [], costBreakdown: ReceiptCostBreakdown())
    }

    @Test func arbitraryLabelCanBeVerifiedBySourceEvidence() {
        let text = "ITEM A £12,50\nSETTLEMENT AMOUNT £12,50"
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.finalTotal, 2, "12.50")
        ], against: text)
        #expect(verified.total == Decimal(string: "12.50"))
    }

    @Test func blankSignatureTotalDoesNotOverridePrintedAmount() {
        let text = "TOTAL DUE $76.16\nTIP ______\nTOTAL ______"
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.finalTotal, 1, "$76.16"),
            proposal(.finalTotal, 3, "$99.99")
        ], against: text)
        #expect(verified.total == Decimal(string: "76.16"))
        #expect(!verified.hasConflictingTotals)
    }

    @Test func bothVerifiedConflictingTotalsRequireReview() {
        let text = "SETTLEMENT $40.00\nCHARGED $41.00"
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.finalTotal, 1, "$40.00"),
            proposal(.finalTotal, 2, "$41.00")
        ], against: text)
        #expect(verified.total == nil)
        #expect(verified.hasConflictingTotals)
        let result = ReceiptSemanticTotalVerifier.apply(verified, to: blank(text))
        #expect(result.costBreakdown?.total == nil)
        #expect(result.reviewWarnings.contains { $0.contains("Conflicting printed") })
    }

    @Test func cannotInventAmountNotOnOCRLine() {
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.finalTotal, 1, "76.16")
        ], against: "CHARGE $71.16")
        #expect(verified.total == nil)
    }

    @Test func priceOnlyContinuationCanBeVerified() {
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.finalTotal, 1, "£79,44")
        ], against: "AMOUNT PAID\n£79,44")
        #expect(verified.total == Decimal(string: "79.44"))
    }

    @Test func cannotBorrowProductPriceFromNextNamedRow() {
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.finalTotal, 1, "15.95")
        ], against: "SETTLEMENT\nRAINBOW ROLL $15.95")
        #expect(verified.total == nil)
    }

    @Test func preserveExistingAuthoritativeTotal() {
        var original = blank("TOTAL £79,44")
        original.costBreakdown?.total = Decimal(string: "79.44")
        let verified = ReceiptSemanticTotalVerifier.Verified(total: Decimal(string: "70.00"))
        let result = ReceiptSemanticTotalVerifier.apply(verified, to: original)
        #expect(result.costBreakdown?.total == Decimal(string: "79.44"))
    }

    @Test func priorConflictCannotBeSilentlyResolved() {
        var original = blank("TOTAL £79,44")
        original.reviewWarnings = ["Conflicting final total values were found across pages."]
        let result = ReceiptSemanticTotalVerifier.apply(
            .init(total: Decimal(string: "79.44")), to: original)
        #expect(result.costBreakdown?.total == nil)
    }

    @Test func independentlyVerifyTaxAndSubtotal() {
        let text = "SUB-TOTAL €70,85\nSTATE TAX €5,31\nSETTLED €76,16"
        let verified = ReceiptSemanticTotalVerifier.verify([
            proposal(.subtotal, 1, "70,85"),
            proposal(.tax, 2, "5,31"),
            proposal(.finalTotal, 3, "76,16")
        ], against: text)
        #expect(verified.subtotal == Decimal(string: "70.85"))
        #expect(verified.tax == Decimal(string: "5.31"))
        #expect(verified.total == Decimal(string: "76.16"))
    }
}

extension ReceiptSemanticTotalVerifierTests {
    @Test func quotedEvidenceRepairsLineNumberWithoutSearchingByAmountAlone() {
        let text = "Page 1\nARTICLE 9,30\nPAYABLE €9,30\nPAID £10,30"
        let verified = ReceiptSemanticTotalVerifier.verify([
            .init(role: .finalTotal, sourceLine: 2, printedAmount: "£9.30", evidence: "PAYABLE 9.30"),
            .init(role: .finalTotal, sourceLine: 3, printedAmount: "€10.30", evidence: "PAID 10.30")
        ], against: text)
        #expect(verified.total == nil)
        #expect(verified.hasConflictingTotals)
        let unsupported = ReceiptSemanticTotalVerifier.verify([
            .init(role: .finalTotal, sourceLine: 1, printedAmount: "9.30", evidence: "IMAGINED 9.30")
        ], against: text)
        #expect(unsupported.total == nil)
    }
}
