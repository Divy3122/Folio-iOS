import Foundation
import Testing
@testable import Folio

struct ReceiptSimpleTotalsTests {
    @Test func printedShippingAndIncludedGSTAreCopied() {
        let text = """
        Page 1
        JB HI-FI Group Pty Ltd
        Apple AirPods Pro With MagSafe Charging Case 2nd Gen $349.00 x1 $349.00
        Subtotal $349.00
        Shipping $10.50
        Total amount paid $359.50
        Includes $31.73 GST
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "349"))
        #expect(amounts.total == Decimal(string: "359.50"))
        #expect(amounts.additionalFees == Decimal(string: "42.23"))
    }

    @Test func printedVATIsIncludedInCharges() {
        let text = """
        SUBTOTAL £66.20
        VAT 20% £13.24
        TOTAL £79.44
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "66.20"))
        #expect(amounts.total == Decimal(string: "79.44"))
        #expect(amounts.additionalFees == Decimal(string: "13.24"))
    }

    @Test func tipBlankTotalLineDoesNotOverrideTotalDue() {
        let text = """
        SUBTOTAL $70.85
        Tax $5.31
        TOTAL DUE $76.16
        TIP
        TOTAL
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.total == Decimal(string: "76.16"))
    }

    @Test func unrelatedNumbersDoNotBecomeSubtotal() {
        let text = """
        Product $349.00
        Shipping $10.50
        Includes $31.73 GST
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == nil)
        #expect(amounts.total == nil)
        #expect(amounts.additionalFees == Decimal(string: "42.23")) // Charges remain independent of missing totals.
    }

    @Test func decimalCommaDoesNotInventNegativeFee() {
        let text = """
        SUB-TOTAL €79,44
        GRAND TOTAL €66,20
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "79.44"))
        #expect(amounts.total == Decimal(string: "66.20"))
        #expect(amounts.additionalFees == nil) // No fee is printed; a difference is not a fee.
    }
}

extension ReceiptSimpleTotalsTests {
    @Test func willowForkVatQualifierAndDecimalComma() {
        let text = """
        Page 1
        THE WILLOW FORK BISTRO
        Garlic Bread x2 £7,80
        Crispy Calamari £6,50
        Pan-Seared Salmon £17,90
        Ribeye Steak 21,50
        House Red £11,00
        Still Water £1,50
        Subtotal (excl. VAT): £66,20
        VAT (20%) £13,24
        Total £79,44
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "66.20"))
        #expect(amounts.total == Decimal(string: "79.44"))
        #expect(amounts.additionalFees == Decimal(string: "13.24"))
    }

    @Test func subtotalWithIncludedTaxQualifier() {
        let text = """
        Subtotal (incl. GST) $349.00
        Shipping $10.50
        Total amount paid $359.50
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "349"))
        #expect(amounts.total == Decimal(string: "359.50"))
    }

    @Test func subtotalLabelFollowedByAmountOnNextOCRLine() {
        let text = """
        Subtotal (excl. VAT):
        £66,20
        VAT (20%) £13,24
        Total
        £79,44
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "66.20"))
        #expect(amounts.total == Decimal(string: "79.44"))
    }

    @Test func doNotTreatUnrelatedTotalHeaderAsFinalAmount() {
        let text = """
        Product Price Qty Total
        Total items 6
        Subtotal (excl. VAT): £66,20
        VAT (20%) £13,24
        Total £79,44
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "66.20"))
        #expect(amounts.total == Decimal(string: "79.44"))
    }
}


private struct TranscriptionRecognizer: ReceiptTextRecognizing {
    func recognize(imageData: Data) async throws -> String { String(decoding: imageData, as: UTF8.self) }
}

extension ReceiptSimpleTotalsTests {
    @Test func preservedCopiedTotalsAndChargesWithoutArithmetic() {
        var draft = ReceiptReviewDraft(.init(subtotal: 100, tax: 5, fees: 2, total: 90))
        ReceiptSimpleTotals.simplify(&draft, ocrText: "Subtotal 100.00\nTax 5.00\nService charge 2.00\nTotal 90.00")
        #expect(draft.subtotal == "100")
        #expect(draft.total == "90")
        #expect(draft.fees == "7") // Printed components, not -10 from balancing totals.
        #expect(draft.tax.isEmpty)
    }

    @Test func preserveModelCopiedAmountsWhenLabelParserCannotReadThem() {
        var draft = ReceiptReviewDraft(.init(subtotal: 12, total: 15))
        ReceiptSimpleTotals.simplify(&draft, ocrText: "Receipt summary\n12.00\n15.00")
        #expect(draft.subtotal == "12")
        #expect(draft.total == "15")
        #expect(draft.fees.isEmpty)
    }

    @Test func refundsKeepPrintedSign() {
        let amounts = ReceiptSimpleTotals.read(ocrText: "Subtotal -10.00\nTotal -10.00")
        #expect(amounts.subtotal == -10)
        #expect(amounts.total == -10)
        #expect(amounts.additionalFees == nil)
    }

    @Test @MainActor func missedReadableProductReachesReviewWithoutBalancing() async {
        let text = "Coffee 4.50\nCake 6.00\nSubtotal 99.00\nTax 1.05\nService charge 2.00\nTotal 102.05"
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in
            GeneratedReceiptCosts(products: [GeneratedReceiptProduct(sourceLine: 2, name: "Coffee",
                evidence: "Coffee 4.50", quantity: nil, unitPrice: nil, lineTotal: nil,
                discount: nil, isReturn: false)], subtotal: nil, discounts: nil, tax: nil,
                fees: [], rounding: nil, total: nil, taxTreatment: .unknown, discountTreatment: .unknown)
        })
        let model = ReceiptScannerViewModel(recognizer: TranscriptionRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.name) == ["Coffee", "Cake"])
        #expect(model.review.products.map(\.lineTotal) == ["4.5", "6"])
        #expect(model.review.subtotal == "99")
        #expect(model.review.total == "102.05")
        #expect(model.review.fees == "3.05")
        #expect(model.warnings.isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func unavailableOrFailedModelKeepsPrintedFields(fails: Bool) async {
        let text = "Tea 3.00\nSubtotal 10.00\nVAT 2.00\nTotal 12.00\nPAYMENT TYPE VISA\nAPP# 11278860"
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { fails ? nil : "Model unavailable" },
            generate: { _ in throw FolioError.extractionUnavailable })
        let model = ReceiptScannerViewModel(recognizer: TranscriptionRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.name) == ["Tea"])
        #expect(model.review.products.first?.lineTotal == "3")
        #expect(model.review.subtotal == "10")
        #expect(model.review.total == "12")
        #expect(model.review.fees == "2")
        #expect(!model.extractionWarnings.isEmpty)
    }

    @Test @MainActor func repeatedProductsOnDifferentPagesAreRetained() async {
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { "Unavailable" })
        let model = ReceiptScannerViewModel(recognizer: TranscriptionRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data("Tea 3,00".utf8), Data("Tea 3,00\nSubtotal 6,00\nTotal 6,00".utf8)])
        #expect(model.review.products.map(\.name) == ["Tea", "Tea"])
        #expect(model.review.products.map(\.lineTotal) == ["3", "3"])
        #expect(model.review.total == "6")
        #expect(model.review.fees.isEmpty)
    }
}

extension ReceiptSimpleTotalsTests {
    @Test func copiedTaxAndOCRFeeDoNotDoubleCount() {
        var draft = ReceiptReviewDraft(.init(subtotal: 100, tax: 10, total: 115))
        ReceiptSimpleTotals.simplify(&draft, ocrText: "Subtotal 100.00\nGST 10.00\nShipping 5.00\nTotal 115.00")
        #expect(draft.fees == "15")
        #expect(draft.total == "115")
    }

    @Test func ambiguousTotalStaysMissing() {
        var draft = ReceiptReviewDraft()
        ReceiptSimpleTotals.simplify(&draft, ocrText: "Total 10.00\nTotal 20.00", allowTotalFallback: false)
        #expect(draft.total.isEmpty)
    }

    @Test func fallbackExcludesSummaryAndPaymentRows() {
        let text = "Roll 15.95\nSubtotal 15.95\nTax 1.00\nTOTAL DUE 16.95\nPAYMENT TYPE VISA\nAPP# 11278860\nApproved 16.95"
        let original = ReceiptExtractionResult(rawText: text, candidate: nil, source: .vision, reviewWarnings: [])
        let result = VerifiedReceiptOCRRecovery.recoverPrintedFields(original, from: text)
        #expect(result.costBreakdown?.products.map(\.name) == ["Roll"])
        #expect(result.costBreakdown?.total == Decimal(string: "16.95"))
    }
}

extension ReceiptSimpleTotalsTests {
    @Test func repeatedNamesKeepTheirOwnDifferentPrintedPrices() {
        let text = "Tea 3.00\nTea 7.00\nSubtotal 10.00\nTotal 10.00"
        let original = ReceiptExtractionResult(rawText: text, candidate: nil, source: .foundationModels,
            reviewWarnings: [], costBreakdown: .init(products: [
                .init(name: "Tea", quantity: nil, unitPrice: nil, lineTotal: 7, discount: nil)
            ]))
        let result = VerifiedReceiptOCRRecovery.recoverPrintedFields(original, from: text)
        #expect(result.costBreakdown?.products.count == 2)
        #expect(result.costBreakdown?.products.compactMap(\.lineTotal).sorted() == [3, 7])
    }
}

extension ReceiptSimpleTotalsTests {
    @Test func semanticSummaryEvidenceCannotBecomeAProductDuringRecovery() {
        let text = "SETTLED 999.00\nCourse 2.00\nVAT 1.00"
        let original = ReceiptExtractionResult(rawText: text, candidate: nil, source: .foundationModels,
            reviewWarnings: [], costBreakdown: .init(total: 999))
        let result = VerifiedReceiptOCRRecovery.recoverPrintedFields(original, from: text, excludedLines: [1])
        #expect(result.costBreakdown?.products.map(\.name) == ["Course"])
        #expect(result.costBreakdown?.total == 999)
    }
}
