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

private struct QualityAuditRecognizer: ReceiptTextRecognizing {
    func recognize(imageData: Data) async throws -> String { String(decoding: imageData, as: UTF8.self) }
}
private struct QualityAuditFailingExtractor: ReceiptExtracting {
    func extract(text: String) async throws -> ReceiptExtractionResult { throw FolioError.extractionUnavailable }
}

extension ReceiptScanQualityAuditTests {
    @Test func conflictingSubtotalsAndSplitAmountRows() {
        let audit = ReceiptScanQualityAudit.inspect(
            text: "Subtotal\n12.00\nSubtotal 13.00\nTotal\n14.00\nTotal 15.00", pages: [], expectedPageCount: 1)
        #expect(audit.ambiguousSubtotal)
        #expect(audit.ambiguousTotal)
    }

    @Test func partialPageEvidenceNeedsReview() {
        let page = ReceiptOCRPage(pageNumber: 1, lines: [])
        let audit = ReceiptScanQualityAudit.inspect(text: "", pages: [page], expectedPageCount: 2)
        #expect(audit.warnings.contains { $0.contains("Some pages") })
    }

    @Test @MainActor func extractionFailureStillDisplaysPrintedTotalsAndCharges() async {
        let text = "Subtotal 10.00\nTax 1.00\nTotal 11.00"
        let model = ReceiptScannerViewModel(recognizer: QualityAuditRecognizer(),
            extractor: QualityAuditFailingExtractor(), draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.subtotal == "10")
        #expect(model.review.fees == "1")
        #expect(model.review.total == "11")
        #expect(!model.extractionWarnings.isEmpty)
        #expect(model.extractedText.contains(text))
    }

    @Test @MainActor func extractionFailureDoesNotChooseAConflictingTotal() async {
        let text = "Subtotal 10.00\nTotal 11.00\nTotal 12.00"
        let model = ReceiptScannerViewModel(recognizer: QualityAuditRecognizer(),
            extractor: QualityAuditFailingExtractor(), draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.subtotal == "10")
        #expect(model.review.total.isEmpty)
        #expect(model.extractionWarnings.contains { $0.contains("Conflicting printed totals") })
    }
}
