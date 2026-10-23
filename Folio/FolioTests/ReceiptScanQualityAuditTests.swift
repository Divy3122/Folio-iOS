import Foundation
import Testing
@testable import Folio

struct ReceiptScanQualityAuditTests {
    @Test func conflictingFinalTotalsRequireReview() {
        let text = "Page 1\nSubtotal $12.00\nGrand Total $14.00\nTotal $15.00"
        let audit = ReceiptScanQualityAudit.inspect(text: text, pages: [], expectedPageCount: 1)
        #expect(audit.ambiguousTotal)
        #expect(!audit.ambiguousSubtotal)
        var draft = ReceiptReviewDraft()
        draft.subtotal = "12.00"
        draft.total = "14.00"
        ReceiptScanQualityAudit.protect(&draft, audit: audit)
        #expect(draft.subtotal == "12.00")
        #expect(draft.total.isEmpty)
    }

    @Test func repeatedMatchingTotalsDoNotConflict() {
        let text = "Subtotal $12.00\nTotal $14.00\nTotal $14.00"
        let audit = ReceiptScanQualityAudit.inspect(text: text, pages: [], expectedPageCount: 1)
        #expect(!audit.ambiguousTotal)
        #expect(!audit.ambiguousSubtotal)
    }

    @Test func lowConfidenceNumbersAreFlagged() {
        let fragment = ReceiptOCRFragment(
            box: ReceiptOCRBox(x: 0.7, y: 0.2, width: 0.2, height: 0.04),
            candidates: [ReceiptOCRCandidate(text: "$18.90", confidence: 0.34)]
        )
        let page = ReceiptOCRPage(pageNumber: 1, lines: [ReceiptOCRLine(fragments: [fragment])])
        let audit = ReceiptScanQualityAudit.inspect(text: "Total $18.90", pages: [page], expectedPageCount: 1)
        #expect(audit.warnings.contains { $0.contains("low-confidence") })
    }
}

extension ReceiptScanQualityAuditTests {
    @Test func consecutiveTotalsCannotHideAConflict() {
        let audit = ReceiptScanQualityAudit.inspect(text: "Total 14.00\nTotal 15.00", pages: [], expectedPageCount: 1)
        #expect(audit.ambiguousTotal)
    }

    @Test func splitAmountRowsAndPartialPages() {
        let page = ReceiptOCRPage(pageNumber: 1, lines: [])
        let audit = ReceiptScanQualityAudit.inspect(
            text: "Subtotal\n12.00\nSubtotal 13.00\nTotal\n14.00\nTotal 15.00", pages: [page], expectedPageCount: 2)
        #expect(audit.ambiguousTotal)
        #expect(audit.ambiguousSubtotal)
        #expect(audit.warnings.contains { $0.contains("Some pages") })
    }
}
