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

extension ReceiptExtractionTests {
    @Test func mapperPreservesOCRPriceDespiteQuoteFormatting() throws {
        let text = "WOVEN BAG   $12,50"
        let value = generated([product("Woven Bag", 1, "Woven Bag 12.50", cost: "12.50")])
        let costs = try #require(result(value, text).costBreakdown)
        #expect(costs.products.first?.lineTotal == Decimal(string: "12.50"))
    }

    @Test func mapperUsesNearbyPriceWithoutBorrowingNextProduct() throws {
        let text = "WOVEN BAG\n$12,50\nGLASS JAR $4.00"
        let value = generated([product("WOVEN BAG", 1, "WOVEN BAG", cost: "12.50")])
        #expect(result(value, text).costBreakdown?.products.first?.lineTotal == Decimal(string: "12.50"))
        let unsupported = generated([product("WOVEN BAG", 1, "WOVEN BAG", cost: "4.00")])
        #expect(result(unsupported, text).costBreakdown?.products.first?.lineTotal == nil)
    }

    @Test @MainActor func printedTotalAndProductReachReviewDespiteMismatch() async {
        let text = "WOVEN BAG $12,50\nGLASS JAR $4.00\nSUBTOTAL $20.00\nSETTLED\n$16,50"
        var value = generated([
            product("WOVEN BAG", 2, "WOVEN BAG", cost: "12.50"),
            product("GLASS JAR", 3, "GLASS JAR", cost: "4.00")
        ], total: amount("16.50", "Settled 16.50"))
        value.subtotal = amount("20.00", "SUBTOTAL 20.00")
        let fixture = value
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in fixture })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.lineTotal) == ["12.5", "4"])
        #expect(model.review.total == "16.5")
        #expect(model.review.subtotal == "20")
        #expect(!ReceiptCostValidator.warnings(for: model.review).isEmpty)
    }

    @Test func recoveryCannotResolvePreviouslyConflictingTotals() {
        let text = "ITEM ONE 3.00\nITEM TWO 4.00\nTOTAL 7.00"
        for warning in ["Conflicting final total values were found across pages.",
                        "Conflicting printed final-total candidates require review."] {
            let original = ReceiptExtractionResult(rawText: text, candidate: nil, source: .foundationModels,
                reviewWarnings: [warning], costBreakdown: ReceiptCostBreakdown())
            let recovered = VerifiedReceiptOCRRecovery.recoverIfComplete(original, from: text)
            #expect(recovered.costBreakdown?.total == nil)
        }
    }

    @Test func existingFocusedRetryStillFillsMissingPrice() async throws {
        let text = "WOVEN BAG $12.50\nSETTLED $12.50"
        let fixture = generated([product("WOVEN BAG", 1, "WOVEN BAG", cost: nil)],
                                total: amount("12.50", "SETTLED 12.50"))
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in fixture },
            generateFocused: { _ in
                [.init(sourceLine: 1, name: "WOVEN BAG", quantity: nil, lineTotal: "12.50", evidence: "WOVEN BAG")]
            })
        let extracted = try await extractor.extract(text: text)
        #expect(extracted.costBreakdown?.products.first?.lineTotal == Decimal(string: "12.50"))
        #expect(extracted.costBreakdown?.total == Decimal(string: "12.50"))
    }
}

extension ReceiptExtractionTests {
    @Test @MainActor func metadataAndBlankTipPipeline() async {
        let text = """
        Rainbow Roll         $15.95
        Spider Roll          $14.95
        750ml Hakutsuru      $39.95

        SUB-TOTAL            $70.85
        TAX                   $5.31

        PAYMENT TYPE         VISA Card
        APP#                 11278860
        REF#                 18623058
        REC#                 0018

        TOTAL DUE            $76.16

        TIP                  ______
        TOTAL                ______
        """
        let proposals = [
            product("Rainbow Roll", 2, "Rainbow Roll 15.95", cost: "15.95"),
            product("Spider Roll", 3, "Spider Roll 14.95", cost: "14.95"),
            product("750ml Hakutsuru", 4, "750ml Hakutsuru 39.95", cost: "39.95"),
            product("SUB-TOTAL", 6, "SUB-TOTAL", cost: "70.85"),
            product("TAX", 7, "TAX", cost: "5.31"),
            product("PAYMENT TYPE", 9, "PAYMENT TYPE"),
            product("APP#", 10, "APP#", cost: "11278860"),
            product("REF#", 11, "REF#", cost: "18623058"),
            product("REC#", 12, "REC#", cost: "0018"),
            product("TOTAL DUE", 14, "TOTAL DUE", cost: "76.16"),
            product("TIP", 16, "TIP"), product("TOTAL", 17, "TOTAL")
        ]
        var initial = generated(proposals)
        initial.taxTreatment = .added
        let fixture = initial
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { prompt in
            var value = fixture
            let numberedLines = prompt.components(separatedBy: .newlines)
            value.products = fixture.products.filter { item in
                numberedLines.contains { $0.hasPrefix("\(item.sourceLine): ") }
            }
            value.subtotal = prompt.contains("6: SUB-TOTAL") ? .init(printed: "70.85", evidence: "SUB TOTAL 70.85") : nil
            value.tax = prompt.contains("7: TAX") ? .init(printed: "5.31", evidence: "TAX 5.31") : nil
            value.total = prompt.contains("17: TOTAL") ? .init(printed: "76.16", evidence: "TOTAL ______") : nil
            return value
        }, generateFocused: { _ in
            [.init(sourceLine: 10, name: "APP#", quantity: nil, lineTotal: "11278860", evidence: "APP#")]
        }, generateTotals: { _ in
            [.init(role: .finalTotal, sourceLine: 14, printedAmount: "76.16"),
             .init(role: .finalTotal, sourceLine: 17, printedAmount: "99.00")]
        })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.name) == ["Rainbow Roll", "Spider Roll", "750ml Hakutsuru"])
        #expect(model.review.products.map(\.lineTotal) == ["15.95", "14.95", "39.95"])
        #expect(model.review.subtotal == "70.85")
        #expect(model.review.tax == "5.31")
        #expect(model.review.total == "76.16")
        #expect(model.extractionWarnings.isEmpty)
        #expect(ReceiptCostValidator.warnings(for: model.review).isEmpty)
    }

    @Test @MainActor func wrappedRestaurantPipeline() async {
        let text = "Roasted Vegetable\nFlatbread 2 x €6,25 €12,50\nSparkling Water €3,50\nSUBTOTAL €16,00\nVAT €3,20\nPAYABLE €19,20"
        var value = generated([
            product("Roasted Vegetable Flatbread", 2, "Roasted Vegetable Flatbread", quantity: "2", unit: "6.25", cost: "12.50"),
            product("Sparkling Water", 4, "Sparkling Water 3.50", cost: "3.50")
        ])
        value.subtotal = amount("16.00", "SUBTOTAL 16.00")
        value.tax = amount("3.20", "VAT 3.20")
        value.taxTreatment = .added
        let fixture = value
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in fixture },
            generateTotals: { _ in [.init(role: .finalTotal, sourceLine: 7, printedAmount: "19.20")] })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.lineTotal) == ["12.5", "3.5"])
        #expect(model.review.products.first?.quantity == "2")
        #expect(model.review.total == "19.2")
        #expect(model.extractionWarnings.isEmpty)
        #expect(ReceiptCostValidator.warnings(for: model.review).isEmpty)
    }

    @Test @MainActor func neighbouringPriceAndConflictingTotalsPipeline() async {
        let text = "Linen Napkin\nGlass Bowl 4.00\nTOTAL 4.00\nTOTAL 8.00"
        let fixture = generated([
            product("Linen Napkin", 2, "Linen Napkin", cost: "4.00"),
            product("Glass Bowl", 3, "Glass Bowl", cost: "4.00")
        ])
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in fixture },
            generateFocused: { _ in [.init(sourceLine: 2, name: "Linen Napkin", quantity: nil, lineTotal: "4.00", evidence: "Linen Napkin")] },
            generateTotals: { _ in [.init(role: .finalTotal, sourceLine: 4, printedAmount: "4.00"),
                                    .init(role: .finalTotal, sourceLine: 5, printedAmount: "8.00")] })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.lineTotal) == ["", "4"])
        #expect(model.review.total.isEmpty)
        #expect(model.extractionWarnings.contains { $0.contains("Conflicting") })
    }
}

extension ReceiptExtractionTests {
    @Test @MainActor func sixProductsSurviveIncorrectAnchorsAndMultipliedPrice() async {
        let text = """
        THE WILLOW FORK BISTRO
        STARTERS
        Garlic Bread x2 € 7,80
        Crispy Calamari £6,50
        MAINS
        Pan-Seared Salmon w/ New Potatoes £17,90
        Ribeye Steak (10oz) w/ Peppercorn Sauce 21,50
        DRINKS
        House Red (175ml) x2 £11,00
        Still Water (750ml) £1,50
        Subtotal (excl. VAT): 66,20
        VAT (20%): 13,24
        Total: 79,44
        Payment Method Visa Credit
        Auth Code 542893
        """
        #expect(ReceiptOCRChunk.split("Page 1\n" + text).count == 1)
        var value = generated([
            product("Garlic Bread", 3, "Garlic Bread x2 € 7,80", quantity: "2", unit: "7.80", cost: "15,60"),
            product("Crispy Calamari", 5, "Crispy Calamari", cost: "6.50"),
            product("Pan-Seared Salmon", 7, "Pan-Seared Salmon", cost: "17.90"),
            product("Ribeye Steak", 8, "Ribeye Steak", cost: "21.50"),
            product("House Red", 10, "House Red", quantity: "2", cost: "11.00"),
            product("Still Water", 10, "Still Water (750ml)", cost: "1.50"),
            product("DRINKS", 9, "DRINKS"), product("Auth Code", 16, "Auth Code", cost: "542893")
        ])
        value.taxTreatment = .added
        let fixture = value
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { _ in fixture },
            generateTotals: { _ in [
                .init(role: .subtotal, sourceLine: 11, printedAmount: "£66.20", evidence: "Subtotal (excl. VAT): 66.20"),
                .init(role: .tax, sourceLine: 12, printedAmount: "€13.24", evidence: "VAT (20%): 13.24"),
                .init(role: .finalTotal, sourceLine: 13, printedAmount: "£79.44", evidence: "Total: 79.44")
            ] })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(text.utf8)])
        #expect(model.review.products.map(\.name) == ["Garlic Bread", "Crispy Calamari", "Pan-Seared Salmon", "Ribeye Steak", "House Red", "Still Water"])
        #expect(model.review.products.map(\.lineTotal) == ["7.8", "6.5", "17.9", "21.5", "11", "1.5"])
        #expect(model.review.products.first?.quantity == "2")
        #expect(model.review.products[4].quantity == "2")
        #expect(model.review.products[0].unitPrice.isEmpty)
        #expect(model.review.subtotal == "66.2")
        #expect(model.review.tax == "13.24")
        #expect(model.review.total == "79.44")
    }

    @Test func incorrectAnchorPreservesIdentityButNotInventedAmount() throws {
        let text = "DRINKS\nSparkling Pear 3,20\nFresh Mint 1,00"
        let value = generated([product("Sparkling Pear", 1, "Sparkling Pear", cost: "6.40")])
        let costs = try #require(result(value, text).costBreakdown)
        #expect(costs.products.map(\.name) == ["Sparkling Pear"])
        #expect(costs.products.first?.lineTotal == nil)
    }

    @Test func longContextRetainsCoverageAndDeduplicates() {
        let text = (1...120).map { "Item \($0) 2.00" }.joined(separator: "\n") + "\nPage 2\nSETTLED 240.00"
        let chunks = ReceiptOCRChunk.split(text)
        #expect(chunks.count > 1)
        let mapped = chunks.map { chunk in
            let products = chunk.lines.enumerated().compactMap { offset, row -> GeneratedReceiptProduct? in
                guard row.hasPrefix("Item ") else { return nil }
                return product(String(row.dropLast(5)), chunk.startLine + offset, row, cost: "2.00")
            }
            return ReceiptExtractionMapper.map(generated(products), chunk: chunk)
        }
        let combined = ReceiptExtractionMapper.combine(mapped, rawText: text)
        #expect(combined.costBreakdown?.products.count == 120)
        #expect(chunks.last?.lines.last == "SETTLED 240.00")
        #expect(chunks.allSatisfy { $0.numberedText.utf8.count <= ReceiptOCRChunk.inputBudget })
    }
}

extension ReceiptExtractionTests {
    @Test @MainActor func unfamiliarMultipageLayoutKeepsPrintedTotalBeforeProducts() async {
        let first = "SETTLED €999,00\nVAT INCLUDED €1,00\n" + (1...40).map { "Course \($0) €2,00" }.joined(separator: "\n")
        let second = (41...80).map { "Course \($0) €2,00" }.joined(separator: "\n") + "\nPAYMENT TYPE CARD\nREF# 123456"
        let empty = generated()
        let extractor = FoundationModelsReceiptExtractor(unavailableReason: { nil }, generate: { prompt in
            var value = empty
            value.products = prompt.components(separatedBy: .newlines).compactMap { row in
                let fields = row.split(separator: ":", maxSplits: 1)
                guard fields.count == 2, let line = Int(fields[0]) else { return nil }
                let content = fields[1].trimmingCharacters(in: .whitespaces)
                guard content.hasPrefix("Course "), let separator = content.range(of: " €") else { return nil }
                return .init(sourceLine: line, name: String(content[..<separator.lowerBound]),
                    evidence: content, quantity: nil, unitPrice: nil, lineTotal: "2.00", discount: nil, isReturn: false)
            }
            value.taxTreatment = .included
            return value
        }, generateTotals: { _ in [
            .init(role: .finalTotal, sourceLine: 1, printedAmount: "£999.00", evidence: "SETTLED 999.00"),
            .init(role: .tax, sourceLine: 2, printedAmount: "1.00", evidence: "VAT INCLUDED 1.00")
        ] })
        let model = ReceiptScannerViewModel(recognizer: FixtureRecognizer(), extractor: extractor, draftStore: nil)
        await model.process(pages: [Data(first.utf8), Data(second.utf8)])
        #expect(model.review.products.count == 80)
        #expect(Set(model.review.products.map(\.name)).count == 80)
        #expect(model.review.products.allSatisfy { $0.lineTotal == "2" })
        #expect(model.review.total == "999")
        #expect(model.review.tax == "1")
        #expect(model.originalPages.count == 2)
        #expect(!ReceiptCostValidator.warnings(for: model.review).isEmpty)
    }
}
