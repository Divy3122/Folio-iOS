import Foundation
import Testing
@testable import Folio

struct ReceiptConsistencyTests {
    @Test func monetaryFormatsShareOneMeaning() {
        for token in ["1,234.56", "1.234,56", "A$1,234.56", "cad 1,234.56"] {
            #expect(ReceiptAmountParser.printed(token) == Decimal(string: "1234.56"))
            let rows = ["Cotton Towel \(token)"]
            let accepted = ReceiptProductEvidenceVerifier.verify([
                .init(sourceLine: 1, name: "Cotton Towel", quantity: nil, lineTotal: token, evidence: rows[0])
            ], lines: rows, startLine: 1)
            #expect(accepted.first?.product.lineTotal == Decimal(string: "1234.56"))
            let base = ReceiptExtractionResult(rawText: rows[0], candidate: nil, source: .vision, reviewWarnings: [])
            #expect(VerifiedReceiptOCRRecovery.recoverPrintedFields(base, from: rows[0]).costBreakdown?.products.first?.lineTotal == Decimal(string: "1234.56"))
        }
    }

    @Test func returnsKeepTheirPrintedSign() {
        for token in ["(4.50)", "4.50-", "-4.50", "(£4.50)"] {
            let rows = ["Returned Shirt \(token)"]
            let accepted = ReceiptProductEvidenceVerifier.verify([
                .init(sourceLine: 1, name: "Returned Shirt", quantity: nil, lineTotal: token, evidence: rows[0])
            ], lines: rows, startLine: 1)
            #expect(accepted.first?.product.lineTotal == Decimal(string: "-4.50"))
            #expect(accepted.first?.product.isReturn == true)
        }
    }

    @Test func explicitCurrencyIntegerIsMoneyButBareIdentifierIsNot() {
        let original = ReceiptExtractionResult(rawText: "", candidate: nil, source: .vision, reviewWarnings: [])
        let result = VerifiedReceiptOCRRecovery.recoverPrintedFields(original, from: "Notebook JPY 400\n123456 400\nTOTAL JPY 400")
        #expect(result.costBreakdown?.products.map(\.name) == ["Notebook"])
        #expect(result.costBreakdown?.products.first?.lineTotal == 400)
        #expect(ReceiptAmountParser.printed("1,234") == nil)
    }

    @Test func conflictingTotalsCannotBecomeAConvenientPrintedValue() {
        let text = "Coffee 3.00\nSubtotal 3.00\nTOTAL 3.00\nTOTAL 5.00"
        let original = ReceiptExtractionResult(rawText: text, candidate: nil, source: .foundationModels,
            reviewWarnings: [], costBreakdown: .init(total: 3))
        let result = VerifiedReceiptOCRRecovery.recoverPrintedFields(original, from: text)
        #expect(result.costBreakdown?.total == nil)
        #expect(result.costBreakdown?.products.first?.lineTotal == 3)
        #expect(!result.reviewWarnings.isEmpty)
        #expect(ReceiptSimpleTotals.read(ocrText: "TOTAL 3.00\nTOTAL 3.00").total == 3)
    }

    @Test func missingProductsStayInPhysicalReceiptOrder() {
        let text = "Coffee 3.00\nSandwich 8.00\nJuice 4.00\nSubtotal 15.00\nTOTAL 15.00"
        let original = ReceiptExtractionResult(rawText: text, candidate: nil, source: .foundationModels,
            reviewWarnings: [], costBreakdown: .init(products: [
                .init(name: "Coffee", quantity: nil, unitPrice: nil, lineTotal: 3, discount: nil),
                .init(name: "Juice", quantity: nil, unitPrice: nil, lineTotal: 4, discount: nil)
            ]))
        let result = VerifiedReceiptOCRRecovery.recoverPrintedFields(original, from: text)
        #expect(result.costBreakdown?.products.map(\.name) == ["Coffee", "Sandwich", "Juice"])
        #expect(result.costBreakdown?.products.first?.id == original.costBreakdown?.products.first?.id)
    }
}

extension ReceiptConsistencyTests {
    @Test func summaryWordsDoNotEraseRealProductNames() {
        for row in ["Total Care Shampoo 8.00", "Tax Free Socks 5.00", "Cash Register 89.00", "Change Purse 6.00"] {
            #expect(ReceiptOCRRowKind.classify(row) == .product)
        }
    }

    @Test func actualSummaryAndPaymentRowsStayExcluded() {
        for row in ["TOTAL DUE 20.00", "TAX INCLUDED 1.00", "TOTAL ITEMS 6", "CASH TENDER 50.00", "CREDIT CARD 20.00"] {
            #expect(ReceiptOCRRowKind.classify(row) != .product)
        }
    }
}

private struct ConsistencyRecognizer: ReceiptTextRecognizing {
    func recognize(imageData: Data) async throws -> String { String(decoding: imageData, as: UTF8.self) }
}

extension ReceiptConsistencyTests {
    @Test @MainActor
    func differentLayoutsReachTheSameReviewContract() async {
        for wrappedCommaLayout in [false, true] {
            let text = wrappedCommaLayout
                ? "Pocket\nNotebook\n3,50\nPen 1,00\nSubtotal 4,50\nVAT 0,45\nTOTAL 4,95\nCASH TENDER 10,00\nTHANK YOU"
                : "Pocket Notebook 3.50\nPen 1.00\nSubtotal 4.50\nVAT 0.45\nTOTAL 4.95\nPAYMENT TYPE CARD\nTHANK YOU"
            let generated = GeneratedReceiptCosts(products: [
                .init(sourceLine: 0, name: "Pocket Notebook", evidence: "Pocket Notebook", quantity: nil,
                      unitPrice: nil, lineTotal: "3.50", discount: nil, isReturn: false),
                .init(sourceLine: 0, name: "Pen", evidence: "Pen", quantity: nil,
                      unitPrice: nil, lineTotal: "1.00", discount: nil, isReturn: false)
            ], subtotal: nil, discounts: nil, tax: nil, fees: [], rounding: nil, total: nil,
               taxTreatment: .unknown, discountTreatment: .unknown)
            let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in generated })
            let model = ReceiptScannerViewModel(recognizer: ConsistencyRecognizer(), extractor: extractor, draftStore: nil)
            await model.process(pages: [Data(text.utf8)])
            #expect(model.review.products.map(\.name) == ["Pocket Notebook", "Pen"])
            #expect(model.review.products.map(\.lineTotal) == ["3.5", "1"])
            #expect(model.review.subtotal == "4.5")
            #expect(model.review.fees == "0.45")
            #expect(model.review.total == "4.95")
            #expect(model.review.tax.isEmpty)
            #expect(model.warnings.isEmpty)
        }
    }

    @Test @MainActor func mainAndFocusedPassAgreeOnUnitVersusLineCost() async {
        let text = "Apples 2 x 2.50 5.00\nSubtotal 5.00\nTOTAL 5.00"
        let generated = GeneratedReceiptCosts(products: [
            .init(sourceLine: 2, name: "Apples", evidence: "Apples 2 x 2.50 5.00", quantity: "2",
                  unitPrice: "2.50", lineTotal: "2.50", discount: nil, isReturn: false)
        ], subtotal: nil, discounts: nil, tax: nil, fees: [], rounding: nil, total: nil,
           taxTreatment: .unknown, discountTreatment: .unknown)
        let mapped = ReceiptExtractionMapper.map(generated, chunk: .init(startLine: 1,
            lines: ("Page 1\n" + text).components(separatedBy: .newlines)))
        #expect(mapped.costs.products.first?.lineTotal == nil)
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in generated },
            generateFocused: { _ in [
                .init(sourceLine: 2, name: "Apples", quantity: "2", lineTotal: "5.00", evidence: "Apples 2 x 2.50 5.00")
            ] })
        let model = ReceiptScannerViewModel(recognizer: ConsistencyRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.count == 1)
        #expect(model.review.products.first?.lineTotal == "5")
    }
}
