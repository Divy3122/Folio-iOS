import Foundation
import Testing
@testable import Folio

private final class ReceiptImageFixtureBundle: NSObject {}
private struct CapturedImageRecognizer: ReceiptEvidenceRecognizing {
    let page: ReceiptOCRPage
    func recognize(imageData: Data) async throws -> String { page.text }
    func recognizeEvidence(imageData: Data) async throws -> ReceiptOCRPage { page }
}

struct ReceiptImageRegressionTests {
    // Captured by Apple Vision from the supplied receipt image, not hand-written OCR.
    private func capturedPage() throws -> ReceiptOCRPage {
        let bundle = Bundle(for: ReceiptImageFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "PrintedReceiptOCR", withExtension: "json"))
        let captured = try JSONDecoder().decode(ReceiptOCRPage.self, from: Data(contentsOf: url))
        return .init(pageNumber: 1, lines: ReceiptOCRLayout.lines(from: captured.lines.flatMap(\.fragments)))
    }

    @Test(arguments: [false, true]) @MainActor
    func suppliedImageOCRReachesReview(focusedRetry: Bool) async throws {
        let page = try capturedPage()
        let text = ReceiptOCREvidencePrompt.renderedText(pages: [page])
        let rows = text.components(separatedBy: .newlines)
        func proposal(_ name: String, _ price: String?, footer: Bool = false) -> GeneratedReceiptProduct {
            let index = footer ? rows.lastIndex(of: name)! : rows.firstIndex(where: { $0.hasPrefix(name) })!
            return .init(sourceLine: index + 1, name: name, evidence: rows[index], quantity: nil,
                         unitPrice: nil, lineTotal: price, discount: nil, isReturn: false)
        }
        // Reproduce the phone output: missing price, tax as product, footer as product.
        let output = GeneratedReceiptCosts(products: [
            proposal("MILK", "3.29"), proposal("BREAD", "2.98"), proposal("EGGS", "4.50"),
            proposal("PAPER TOWELS", nil), proposal("SALES TAX", "1.53"), proposal("WALMART", nil, footer: true)
        ], subtotal: .init(printed: "19.74", evidence: "SUBTOTAL 19.74"), discounts: nil,
           tax: nil, fees: [], rounding: nil, total: .init(printed: "21.27", evidence: "TOTAL 21.27"),
           taxTreatment: .unknown, discountTreatment: .unknown)
        let paperLine = rows.firstIndex(where: { $0.hasPrefix("PAPER TOWELS") })! + 1
        let focused: FoundationModelsReceiptExtractor.GenerateFocused? = focusedRetry ? { _ in
            [.init(sourceLine: paperLine, name: "PAPER TOWELS", quantity: nil,
                   lineTotal: "8.97", evidence: "PAPER TOWELS 8.97")]
        } : nil
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in output },
                                                        generateFocused: focused)
        let model = ReceiptScannerViewModel(recognizer: CapturedImageRecognizer(page: page), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data([1, 2, 3])])
        #expect(model.review.products.map(\.name) == ["MILK", "BREAD", "EGGS", "PAPER TOWELS"])
        #expect(model.review.products.map(\.lineTotal) == ["3.29", "2.98", "4.5", "8.97"])
        #expect(model.review.subtotal == "19.74")
        #expect(model.review.fees == "1.53")
        #expect(model.review.total == "21.27")
        #expect(model.warnings.isEmpty)
        #expect(model.originalPages == [Data([1, 2, 3])])
        #expect(model.extractedText == text)
    }

    @Test @MainActor func suppliedImageWithoutAppleIntelligence() async throws {
        let page = try capturedPage()
        let model = ReceiptScannerViewModel(recognizer: CapturedImageRecognizer(page: page),
            extractor: FoundationModelsReceiptExtractor(unavailableReason: { "Unavailable" }), draftStore: nil)
        await model.process(pages: [Data([1])])
        #expect(model.review.products.count == 4)
        #expect(model.review.products.last?.lineTotal == "8.97")
        #expect(model.review.fees == "1.53")
        #expect(model.review.total == "21.27")
    }

    @Test func unrelatedProductDoesNotConsumeFollowingNumericRow() throws {
        let text = "Dish Cloth 6,43\n987654 18,11\nSUBTOTAL 18,11"
        let chunk = ReceiptOCRChunk(startLine: 1, lines: text.components(separatedBy: .newlines))
        let anchor = try #require(ReceiptExtractionMapper.productAnchor(name: "Dish Cloth", sourceLine: 1, chunk: chunk))
        #expect(anchor.context == "Dish Cloth 6,43")
        let accepted = ReceiptProductEvidenceVerifier.verify([
            .init(sourceLine: 1, name: "Dish Cloth", quantity: nil, lineTotal: "6.43", evidence: "Dish Cloth 6,43")
        ], lines: chunk.lines, startLine: 1)
        #expect(accepted.first?.product.lineTotal == Decimal(string: "6.43"))
    }

    @Test func footerFilterResetsOnNextPage() {
        let rows = ["Page 1", "CASH TENDER 10.00", "THANK YOU", "Some Shop", "Page 2", "Coffee 3.00"]
        #expect(!ReceiptOCRRowKind.isProductRow(at: 3, lines: rows))
        #expect(ReceiptOCRRowKind.isProductRow(at: 5, lines: rows))
        #expect(ReceiptOCRRowKind.classify("SALES TAX 8.2500 1.21") == .financialSummary)
    }
}
