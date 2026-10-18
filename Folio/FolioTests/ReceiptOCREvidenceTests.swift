import Foundation
import Testing
@testable import Folio

struct ReceiptOCREvidenceTests {
    private func fragment(
        _ text: String,
        x: Double,
        y: Double,
        confidence: Double = 0.9,
        alternative: String? = nil
    ) -> ReceiptOCRFragment {
        let best = ReceiptOCRCandidate(text: text, confidence: confidence)
        let candidates = [best] + (alternative.map {
            [ReceiptOCRCandidate(text: $0, confidence: 0.45)]
        } ?? [])
        return .init(box: .init(x: x, y: y, width: 0.12, height: 0.025), candidates: candidates)
    }

    @Test func reconstructsRowsByVerticalPositionAndLeftToRight() {
        let result = ReceiptOCRLayout.lines(from: [
            fragment("£7,80", x: 0.77, y: 0.70),
            fragment("TOTAL", x: 0.09, y: 0.10),
            fragment("Garlic Bread x2", x: 0.10, y: 0.70)
        ])
        #expect(result.map(\.text) == ["Garlic Bread x2   £7,80", "TOTAL"])
        #expect(result[0].box != nil)
    }

    @Test func preservesRankedOCRAlternativesAndConfidence() {
        let suspect = fragment("€7,30", x: 0.8, y: 0.5, confidence: 0.42, alternative: "£7,80")
        #expect(suspect.text == "€7,30")
        #expect(suspect.confidence == 0.42)
        #expect(suspect.alternatives.first?.text == "£7,80")
        #expect(suspect.box.y == 0.5)
    }

    @Test func onlyAddsAlternativesToMatchingSourceLines() {
        let line = ReceiptOCRLine(fragments: [
            fragment("Garlic Bread x2", x: 0.1, y: 0.4),
            fragment("€7,30", x: 0.8, y: 0.4, confidence: 0.42, alternative: "£7,80")
        ])
        let page = ReceiptOCRPage(pageNumber: 1, lines: [line])
        let text = ReceiptOCREvidencePrompt.renderedText(pages: [page])
        let context = ReceiptOCREvidencePrompt.focusedContext(
            numberedOCR: "2: \(line.text)", chunkStartLine: 2,
            chunkLines: [line.text], originalText: text, pages: [page]
        )
        #expect(context.contains("Line 2"))
        #expect(context.contains("£7,80"))
        #expect(context.contains("not verified"))
        #expect(context.contains("€7,30"))
    }

    @Test func refusesStaleEvidenceFromDifferentReceipt() {
        let page = ReceiptOCRPage(pageNumber: 1, lines: [
            ReceiptOCRLine(fragments: [fragment("£7,30", x: 0.8, y: 0.4, alternative: "£7,80")])
        ])
        let original = "2: other receipt"
        let context = ReceiptOCREvidencePrompt.focusedContext(
            numberedOCR: original, chunkStartLine: 2,
            chunkLines: ["other receipt"], originalText: "Page 1\nother receipt", pages: [page]
        )
        #expect(context == original)
    }

    @Test func indexesEvidenceAcrossMultiplePages() {
        let first = ReceiptOCRPage(pageNumber: 1, lines: [
            ReceiptOCRLine(fragments: [fragment("FIRST", x: 0.1, y: 0.8)])
        ])
        let second = ReceiptOCRPage(pageNumber: 2, lines: [
            ReceiptOCRLine(fragments: [fragment("€7,30", x: 0.8, y: 0.6, confidence: 0.4, alternative: "£7,80")])
        ])
        let raw = ReceiptOCREvidencePrompt.renderedText(pages: [first, second])
        let context = ReceiptOCREvidencePrompt.focusedContext(
            numberedOCR: "5: €7,30", chunkStartLine: 5,
            chunkLines: ["€7,30"], originalText: raw, pages: [first, second]
        )
        #expect(context.contains("Line 5"))
        #expect(context.contains("£7,80"))
    }

    @Test func roundTripsThroughLocalJSON() throws {
        let page = ReceiptOCRPage(pageNumber: 1, lines: [
            ReceiptOCRLine(fragments: [fragment("£7,30", x: 0.8, y: 0.4, confidence: 0.33, alternative: "£7,80")])
        ])
        let encoded = try JSONEncoder().encode([page])
        let decoded = try JSONDecoder().decode([ReceiptOCRPage].self, from: encoded)
        #expect(decoded == [page])
    }
}
