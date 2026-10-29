import Foundation
import Testing
@testable import Folio

private final class ReceiptImageFixtureBundle {}

private struct CapturedImageRecognizer: ReceiptTextRecognizing {
    let page: ReceiptOCRPage
    func recognize(imageData: Data) async throws -> String {
        ReceiptOCREvidencePrompt.renderedText(pages: [page])
    }
}

struct ReceiptImageRegressionTests {
    private func capturedPage() throws -> ReceiptOCRPage {
        let bundle = Bundle(for: ReceiptImageFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "PrintedReceiptOCR", withExtension: "json"))
        let captured = try JSONDecoder().decode(ReceiptOCRPage.self, from: Data(contentsOf: url))
        return .init(pageNumber: 1, lines: ReceiptOCRLayout.lines(from: captured.lines.flatMap(\.fragments)))
    }

    @Test @MainActor
    func suppliedImageOCRReachesReview() async throws {
        for focusedRetry in [false, true] {
            let page = try capturedPage()
            let text = ReceiptOCREvidencePrompt.renderedText(pages: [page])
            let rows = text.components(separatedBy: .newlines)
            func proposal(_ name: String, _ price: String?, footer: Bool = false) -> GeneratedReceiptProduct {
                let index = footer ? rows.lastIndex(of: name)! : rows.firstIndex(where: { $0.hasPrefix(name) })!
                return .init(sourceLine: index + 1, name: name, evidence: rows[index], quantity: nil,
                             unitPrice: nil, lineTotal: price, discount: nil, isReturn: false)
            }
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
            #expect(model.extractedText == "Page 1\n\(text)")
        }
    }

    @Test @MainActor func suppliedImageWithoutAppleIntelligence() async throws {
        let page = try capturedPage()
        let model = ReceiptScannerViewModel(recognizer: CapturedImageRecognizer(page: page),
                                            extractor: FoundationModelsReceiptExtractor(unavailableReason: { "Unavailable" }), draftStore: nil)
        await model.process(pages: [Data([1, 2, 3])])
        #expect(model.review.products.map(\.name) == ["MILK", "BREAD", "EGGS", "PAPER TOWELS"])
        #expect(model.review.products.map(\.lineTotal) == ["3.29", "2.98", "4.5", "8.97"])
        #expect(model.review.subtotal == "19.74")
        #expect(model.review.fees == "1.53")
        #expect(model.review.total == "21.27")
        #expect(model.extractionWarnings.contains { $0.localizedCaseInsensitiveContains("unavailable") },
                "Actual warnings: \(model.extractionWarnings)")
    }

    @Test func unrelatedProductDoesNotConsumeFollowingNumericRow() throws {
        let page = try capturedPage()
        let text = ReceiptOCREvidencePrompt.renderedText(pages: [page])
        let accepted = ReceiptProductEvidenceVerifier.verify([
            .init(sourceLine: 25, name: "MILK", quantity: nil, lineTotal: "3.29", evidence: "MILK 3.29"),
            .init(sourceLine: 35, name: "NO MATCH", quantity: nil, lineTotal: nil, evidence: "NO MATCH")
        ], lines: text.components(separatedBy: .newlines), startLine: 1)
        #expect(accepted.count == 1)
        #expect(accepted.first?.product.lineTotal == Decimal(string: "3.29"))
    }

    @Test func footerFilterResetsOnNextPage() {
        let text = "Page 1\nTOTAL 10.00\nTHANK YOU FOR SHOPPING\nPage 2\nCOFFEE 4.00\nTOTAL 14.00"
        let recovery = VerifiedReceiptOCRRecovery.recoverPrintedFields(
            .init(rawText: text, candidate: nil, source: .vision, reviewWarnings: []),
            from: text
        )
        #expect(recovery.costBreakdown?.products.contains { $0.name == "COFFEE" } == true)
    }
}
