//
//  ReceiptOptionalFieldTests.swift
//  Folio
//
//  Created by Divy Patel on 18/10/2026.
//

import Testing
@testable import Folio

@Suite("Optional receipt fields")
struct ReceiptOptionalFieldTests {
    private func basicReview() -> ReceiptReviewDraft {
        var draft = ReceiptReviewDraft()
        var item = ReceiptReviewDraft.Product()
        item.name = "Sample item"
        item.lineTotal = "12.50"
        draft.products = [item]
        draft.total = "12.50"
        return draft
    }

    @Test func absentOptionalAmountsDoNotRequireReview() {
        let draft = basicReview()
        #expect(ReceiptCostValidator.warnings(for: draft).isEmpty)
    }

    @Test func rejectedOptionalAISuggestionsAreDiagnosticsOnly() {
        let draft = basicReview()
        let warnings = [
            "Sample item discount could not be verified against the OCR and was left missing.",
            "Sample item quantity could not be verified against the OCR and was left missing.",
            "An additional fee could not be verified. Check the fee total manually.",
            "Discounts could not be verified against the OCR and was left missing."
        ]
        #expect(ReceiptReviewAttention.notes(for: draft, extractionWarnings: warnings).isEmpty)
    }

    @Test func genuinelyMissingTotalStillRequiresReview() {
        var draft = basicReview()
        draft.total = ""
        let notes = ReceiptReviewAttention.notes(for: draft, extractionWarnings: [])
        #expect(notes.contains { $0.contains("Final total is missing") })
    }

    @Test func invalidUserEnteredDiscountStillRequiresReview() {
        var draft = basicReview()
        draft.discounts = "not a price"
        let notes = ReceiptReviewAttention.notes(for: draft, extractionWarnings: [])
        #expect(notes.contains { $0.contains("Discounts:") })
    }
}
