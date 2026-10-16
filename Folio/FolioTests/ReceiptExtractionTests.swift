import Foundation
import Testing
@testable import Folio

private struct FixtureRecognizer: ReceiptTextRecognizing {
    func recognize(imageData: Data) async throws -> String {
        let text = String(decoding: imageData, as: UTF8.self)
        if text == "OCR_FAILURE" { throw FolioError.extractionUnavailable }
        return text
    }
}

private struct FixtureExtractor: ReceiptExtracting {
    let result: ReceiptExtractionResult
    func extract(text: String) async throws -> ReceiptExtractionResult { result }
}

private actor PausedExtractor: ReceiptExtracting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func extract(text: String) async throws -> ReceiptExtractionResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return ReceiptExtractionResult(rawText: text, candidate: nil, source: .foundationModels, reviewWarnings: [],
            costBreakdown: ReceiptCostBreakdown(total: 999))
    }
    func finish() { continuation?.resume(); continuation = nil }
}

struct ReceiptExtractionTests {
    private func amount(_ token: String, _ evidence: String) -> GeneratedReceiptAmount {
        GeneratedReceiptAmount(printed: token, evidence: evidence)
    }
    private func product(_ name: String, _ line: Int, _ evidence: String,
                         quantity: String? = nil, unit: String? = nil, cost: String? = nil,
                         discount: String? = nil, isReturn: Bool = false) -> GeneratedReceiptProduct {
        GeneratedReceiptProduct(sourceLine: line, name: name, evidence: evidence,
            quantity: quantity, unitPrice: unit, lineTotal: cost, discount: discount, isReturn: isReturn)
    }
    private func generated(_ products: [GeneratedReceiptProduct] = [], total: GeneratedReceiptAmount? = nil) -> GeneratedReceiptCosts {
        GeneratedReceiptCosts(products: products, subtotal: nil, discounts: nil, tax: nil, fees: [],
            rounding: nil, total: total, taxTreatment: .unknown, discountTreatment: .unknown)
    }
    private func result(_ value: GeneratedReceiptCosts, _ text: String) -> ReceiptExtractionResult {
        let chunk = ReceiptOCRChunk(startLine: 1, lines: text.components(separatedBy: .newlines))
        return ReceiptExtractionMapper.combine([ReceiptExtractionMapper.map(value, chunk: chunk)], rawText: text)
    }

    @Test func standardRetailReceiptExcludesPaymentMetadata() throws {
        let text = "SHOP\nMILK 4.50\nBREAD 3.00\nTOTAL 7.50\nCASH 10.00\nCHANGE 2.50"
        let value = generated([
            product("MILK", 2, "MILK 4.50", cost: "4.50"),
            product("BREAD", 3, "BREAD 3.00", cost: "3.00"),
            product("CASH", 5, "CASH 10.00", cost: "10.00"),
            product("CHANGE", 6, "CHANGE 2.50", cost: "2.50")
        ], total: amount("7.50", "TOTAL 7.50"))
        let extracted = result(value, text)
        let costs = try #require(extracted.costBreakdown)
        #expect(costs.products.map(\.name) == ["MILK", "BREAD"])
        #expect(costs.total == Decimal(string: "7.50"))
        #expect(costs.products[0].quantity == nil)
        #expect(costs.products[0].unitPrice == nil)
        #expect(extracted.candidate == nil) // No invented retailer, date or currency to force a saved receipt.
        #expect(extracted.rawText == text)
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
    }

    @Test func quantitiesWrappedProductsAndRepeatedPurchases() throws {
        let text = "ORG APP\n2 x 1.25\n2.50\nBANANAS 0.500 x 4.00 2.00\nMILK 3.00\nMILK 3.00\nTOTAL 10.50"
        let value = generated([
            product("ORG APP", 1, "ORG APP\n2 x 1.25\n2.50", quantity: "2", unit: "1.25", cost: "2.50"),
            product("BANANAS", 4, "BANANAS 0.500 x 4.00 2.00", quantity: "0.500", unit: "4.00", cost: "2.00"),
            product("MILK", 5, "MILK 3.00", cost: "3.00"),
            product("MILK", 6, "MILK 3.00", cost: "3.00")
        ], total: amount("10.50", "TOTAL 10.50"))
        let costs = try #require(result(value, text).costBreakdown)
        #expect(costs.products.count == 4)
        #expect(costs.products[1].quantity == Decimal(string: "0.5"))
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
    }

    @Test func discountsAndGSTInclusiveTotalAreNotDoubleCounted() throws {
        let text = "ITEM 22.00\nSUBTOTAL 22.00\nDISCOUNT -2.00\nGST INCLUDED 1.82\nTOTAL 20.00"
        var value = generated([product("ITEM", 1, "ITEM 22.00", cost: "22.00")], total: amount("20.00", "TOTAL 20.00"))
        value.subtotal = amount("22.00", "SUBTOTAL 22.00")
        value.discounts = amount("-2.00", "DISCOUNT -2.00")
        value.tax = amount("1.82", "GST INCLUDED 1.82")
        value.taxTreatment = .included
        value.discountTreatment = .deductedFromLines
        let costs = try #require(result(value, text).costBreakdown)
        #expect(costs.discounts == 2)
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
        var included = costs
        included.products[0].lineTotal = 20
        included.subtotal = 20
        included.discountTreatment = .includedInLines
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(included)).isEmpty)
    }

    @Test func missingAndUnsupportedPricesStayMissing() throws {
        let text = "BREAD ?.??\nMILK 3.OO\nTOTAL unreadable"
        let value = generated([
            product("BREAD", 1, "BREAD ?.??", cost: nil),
            product("MILK", 2, "MILK 3.OO", cost: "3.00")
        ], total: amount("8.00", "TOTAL unreadable"))
        let extracted = result(value, text)
        let costs = try #require(extracted.costBreakdown)
        #expect(costs.products.count == 2)
        #expect(costs.products.allSatisfy { $0.lineTotal == nil })
        #expect(costs.total == nil)
        #expect(!extracted.reviewWarnings.isEmpty)
        let warnings = ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs))
        #expect(warnings.contains { $0.contains("Final total is missing") })
    }

    @Test func mismatchedTotalsAreWarnedAndNeverReplaced() {
        let costs = ReceiptCostBreakdown(products: [.init(name: "Item", quantity: nil, unitPrice: nil, lineTotal: 10)], total: 15)
        let draft = ReceiptReviewDraft(costs)
        #expect(ReceiptCostValidator.warnings(for: draft).contains { $0.contains("differ from the final total by 5") })
        #expect(draft.costs.total == 15)
    }

    @Test func returnsFeesAddedTaxAndRounding() {
        let costs = ReceiptCostBreakdown(products: [
            .init(name: "New item", quantity: 2, unitPrice: 10, lineTotal: 18, discount: 2),
            .init(name: "Returned item", quantity: 1, unitPrice: 5, lineTotal: -5, isReturn: true)
        ], subtotal: 13, tax: Decimal(string: "1.30"), fees: 1, rounding: Decimal(string: "-0.01"),
           total: Decimal(string: "15.29"), taxTreatment: .added)
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
    }

    @Test func invalidNumbersAndUnknownTreatmentRequireReview() {
        for input in ["NaN", "10abc", "1.2.3", "1e3", "99999999999999999999999999999999999999999"] {
            #expect(ReceiptAmountParser.parse(input) == nil)
        }
        #expect(ReceiptAmountParser.printed("$1,234.50") == Decimal(string: "1234.50"))
        #expect(ReceiptAmountParser.printed("1,234") == nil)
        #expect(ReceiptAmountParser.printed("2,50") == Decimal(string: "2.50"))
        #expect(ReceiptAmountParser.printed("(3.00)") == -3)
        var draft = ReceiptReviewDraft(ReceiptCostBreakdown(products: [.init(name: "Item", quantity: 0, unitPrice: -2, lineTotal: 10)], tax: 1, total: 10))
        draft.fees = "bad"
        let warnings = ReceiptCostValidator.warnings(for: draft)
        #expect(warnings.contains { $0.contains("quantity must be greater") })
        #expect(warnings.contains { $0.contains("unit price cannot be negative") })
        #expect(warnings.contains { $0.contains("Confirm whether GST") })
        #expect(draft.fees == "bad")
    }

    @Test func unavailableModelNeverCallsGeneration() async throws {
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { "Model unavailable" }, generate: { _ in
            Issue.record("Generation must not run on an unavailable model")
            throw FolioError.extractionUnavailable
        })
        let extracted = try await extractor.extract(text: "OCR stays intact")
        #expect(extracted.rawText == "OCR stays intact")
        #expect(extracted.costBreakdown?.products.isEmpty == true)
        #expect(extracted.costBreakdown?.total == nil)
        #expect(extracted.reviewWarnings == ["Model unavailable"])
        if case .foundationModels = extracted.source { Issue.record("Unavailable model cannot report model success") }
    }

    @Test func generationFailureRetainsOCR() async throws {
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in
            throw FolioError.extractionUnavailable
        })
        let extracted = try await extractor.extract(text: "Page 1\nBREAD 3.00")
        #expect(extracted.rawText == "Page 1\nBREAD 3.00")
        #expect(extracted.costBreakdown?.total == nil)
        #expect(extracted.reviewWarnings.contains { $0.contains("extraction failed") })
    }

    @Test func multipageOCRAndOverlapPreserveEveryDistinctProduct() throws {
        let text = "Page 1\nBREAD 3.00\nMILK\nPage 2\n2 x 4.00 8.00\nTOTAL 11.00"
        let value = generated([
            product("BREAD", 2, "BREAD 3.00", cost: "3.00"),
            product("MILK", 3, "MILK\nPage 2\n2 x 4.00 8.00", quantity: "2", unit: "4.00", cost: "8.00")
        ], total: amount("11.00", "TOTAL 11.00"))
        let chunk = ReceiptOCRChunk(startLine: 1, lines: text.components(separatedBy: .newlines))
        let mapped = ReceiptExtractionMapper.map(value, chunk: chunk)
        let extracted = ReceiptExtractionMapper.combine([mapped, mapped], rawText: text)
        let costs = try #require(extracted.costBreakdown)
        #expect(costs.products.count == 2)
        #expect(costs.total == 11)
        #expect(extracted.rawText.contains("Page 2"))
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
        let longText = (1...60).map { "Product \($0) 10.00" }.joined(separator: "\n")
        let chunks = ReceiptOCRChunk.split(longText, limit: 180)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.lines.count <= 16 })
        #expect(chunks.last?.startLine ?? 0 > 1)
        let covered = Set(chunks.flatMap { chunk in chunk.lines.indices.map { chunk.startLine + $0 } })
        #expect(covered == Set(1...60))
    }

    @Test func conflictingPrintedTotalsStayMissing() {
        let one = ReceiptExtractionMapper.map(generated(total: amount("10.00", "TOTAL 10.00")), chunk: .init(startLine: 1, lines: ["TOTAL 10.00"]))
        let two = ReceiptExtractionMapper.map(generated(total: amount("12.00", "TOTAL 12.00")), chunk: .init(startLine: 2, lines: ["TOTAL 12.00"]))
        let extracted = ReceiptExtractionMapper.combine([one, two], rawText: "TOTAL 10.00\nTOTAL 12.00")
        #expect(extracted.costBreakdown?.total == nil)
        #expect(extracted.reviewWarnings.contains { $0.contains("Conflicting final total") })
    }

    @Test @MainActor func scannerRetainsAllPagesAndPartialOCR() async {
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { "Unavailable" })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        let pages = [Data("BREAD 3.00".utf8), Data("OCR_FAILURE".utf8), Data("TOTAL 3.00".utf8)]
        await model.process(pages: pages)
        #expect(model.originalPages == pages)
        #expect(model.pageCount == 3)
        #expect(model.extractedText == "Page 1\nBREAD 3.00\n\nPage 3\nTOTAL 3.00")
        #expect(model.extractionWarnings.contains { $0.contains("OCR failed on page 2") })
        #expect(!model.isProcessing)
    }

    @Test @MainActor func lateExtractionCannotOverwriteManualEdits() async {
        let extractor = PausedExtractor()
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        let task = Task { await model.process(pages: [Data("ITEM 10.00".utf8)]) }
        while !(await extractor.started) { await Task.yield() }
        model.addProduct()
        model.review.products[0].name = "My correction"
        model.review.total = "12.50"
        await extractor.finish()
        await task.value
        #expect(model.review.total == "12.50")
        #expect(model.review.products[0].name == "My correction")
        #expect(model.extractionWarnings.contains { $0.contains("you edited") })
    }

    @Test @MainActor func localDraftRestoresEditsOCRAndOriginalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReceiptScannerDraftStore(url: directory.appending(path: "draft.json"))
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { "Unavailable" })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: store)
        let pages = [Data("ITEM 2.00".utf8), Data("TOTAL 2.00".utf8)]
        await model.process(pages: pages)
        model.addProduct()
        model.review.products[0].name = "Corrected item"
        model.review.total = "2.00"
        await model.saveDraft()
        let restored = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: store)
        await restored.restoreDraft()
        #expect(restored.originalPages == pages)
        #expect(restored.extractedText == model.extractedText)
        #expect(restored.review == model.review)
        #expect(restored.storageWarning == nil)
    }
}

extension ReceiptExtractionTests {
    @Test func separateFeesAreSummedOnceAcrossOverlappingChunks() throws {
        let text = "ITEM 10.00\nBAG FEE 0.20\nSURCHARGE 0.30\nTOTAL 10.50"
        var value = generated([product("ITEM", 1, "ITEM 10.00", cost: "10.00")], total: amount("10.50", "TOTAL 10.50"))
        value.fees = [
            GeneratedReceiptFee(sourceLine: 2, amount: amount("0.20", "BAG FEE 0.20")),
            GeneratedReceiptFee(sourceLine: 3, amount: amount("0.30", "SURCHARGE 0.30"))
        ]
        let mapped = ReceiptExtractionMapper.map(value, chunk: .init(startLine: 1, lines: text.components(separatedBy: .newlines)))
        let extracted = ReceiptExtractionMapper.combine([mapped, mapped], rawText: text)
        let costs = try #require(extracted.costBreakdown)
        #expect(costs.fees == Decimal(string: "0.50"))
        #expect(ReceiptCostValidator.warnings(for: ReceiptReviewDraft(costs)).isEmpty)
    }

    @Test func serviceMapsGuidedOutputThroughSharedContract() async throws {
        let fixture = generated([product("ITEM", 1, "ITEM 10.00", cost: "10.00")], total: amount("10.00", "TOTAL 10.00"))
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { text in
            #expect(text.contains("1: ITEM 10.00"))
            return fixture
        })
        let extracted = try await extractor.extract(text: "ITEM 10.00\nTOTAL 10.00")
        #expect(extracted.costBreakdown?.total == 10)
        #expect(extracted.costBreakdown?.products.count == 1)
        #expect(extracted.reviewWarnings.isEmpty)
    }

    @Test func partialChunkFailureKeepsSupportedProducts() async throws {
        let fixture = generated([product("ITEM", 1, "ITEM 10.00", cost: "10.00")])
        let text = "ITEM 10.00\n" + String(repeating: "RECEIPT METADATA\n", count: 400)
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { prompt in
            if prompt.hasPrefix("1: ITEM") { return fixture }
            throw FolioError.extractionUnavailable
        })
        let extracted = try await extractor.extract(text: text)
        #expect(extracted.costBreakdown?.products.count == 1)
        #expect(extracted.reviewWarnings.contains { $0.contains("extraction failed") })
        #expect(extracted.rawText == text)
    }

    @Test @MainActor func unreadableScanKeepsImagesAndEditableEmptyReview() async {
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: FoundationModelsReceiptExtractor(unavailableReason: { "Unavailable" }), draftStore: nil)
        let pages = [Data("   ".utf8)]
        await model.process(pages: pages)
        #expect(model.originalPages == pages)
        #expect(model.errorMessage != nil)
        #expect(model.review.total.isEmpty)
        model.addProduct()
        model.review.products[0].name = "Manual product"
        #expect(model.review.products[0].name == "Manual product")
    }

    @Test @MainActor func cancelledExtractionKeepsOCRAndEdits() async {
        let extractor = PausedExtractor()
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        let pages = [Data("ITEM 10.00".utf8)]
        let task = Task { await model.process(pages: pages) }
        while !(await extractor.started) { await Task.yield() }
        model.review.total = "10.00"
        task.cancel()
        await extractor.finish()
        await task.value
        #expect(model.review.total == "10.00")
        #expect(model.originalPages == pages)
        #expect(model.extractedText.contains("ITEM 10.00"))
        #expect(model.extractionWarnings.contains { $0.contains("cancelled") })
    }
}


extension ReceiptExtractionTests {
    @Test @MainActor func manualTotalAndRemovingLastProductPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReceiptScannerDraftStore(url: directory.appending(path: "draft.json"))
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), draftStore: store)
        model.review.total = "9.00"
        #expect(model.hasReview)
        await model.saveDraft()
        #expect(try await store.load()?.review.total == "9.00")
        model.addProduct()
        let id = try #require(model.review.products.first?.id)
        await model.saveDraft()
        model.removeProduct(id: id)
        model.review.total = ""
        await model.saveDraft()
        #expect(try await store.load()?.review.products.isEmpty == true)
        #expect(try await store.load()?.review.total == "")
    }
}
