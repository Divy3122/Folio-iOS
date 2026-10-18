import Foundation
import Observation

@MainActor
@Observable
final class ReceiptScannerViewModel {
    private(set) var extractedText = ""
    private(set) var originalPages: [Data] = []
    private(set) var ocrEvidencePages: [ReceiptOCRPage] = []
    private(set) var pageCount = 0
    private(set) var isProcessing = false
    private(set) var processingMessage = "Recognising receipt text…"
    private(set) var errorMessage: String?
    private(set) var extractionWarnings: [String] = []
    private(set) var storageWarning: String?
    // Available only in debug builds; not saved to local draft storage.
    private(set) var pipelineDebugReport = "No new scan has been processed in this session."
    var review = ReceiptReviewDraft() {
        didSet {
            if !applyingExtraction {
                editRevision += 1
                hasDraftSession = true
                scheduleSave()
            }
        }
    }

    private var hasDraftSession = false

    @ObservationIgnored private let recognizer: any ReceiptTextRecognizing
    @ObservationIgnored private let extractor: any ReceiptExtracting
    @ObservationIgnored private let draftStore: ReceiptScannerDraftStore?
    @ObservationIgnored private var editRevision = 0
    @ObservationIgnored private var applyingExtraction = false
    @ObservationIgnored private var restoreAttempted = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(recognizer: any ReceiptTextRecognizing = VisionReceiptTextRecognizer(),
         extractor: any ReceiptExtracting = FoundationModelsReceiptExtractor.live(),
         draftStore: ReceiptScannerDraftStore? = .live()) {
        self.recognizer = recognizer
        self.extractor = extractor
        self.draftStore = draftStore
    }

    var warnings: [String] { extractionWarnings + ReceiptCostValidator.warnings(for: review) }
    var hasReview: Bool { hasDraftSession || !originalPages.isEmpty || !extractedText.isEmpty || !review.products.isEmpty }

    func beginManualReceipt() {
        guard !isProcessing else { return }
        editRevision += 1
        hasDraftSession = true
        originalPages = []
        ocrEvidencePages = []
        pageCount = 0
        extractedText = ""
        errorMessage = nil
        extractionWarnings = []
        pipelineDebugReport = "Manual entry: no AI extraction was requested."
        apply(ReceiptReviewDraft())
        scheduleSave()
    }

    func addProduct() { review.products.append(.init()) }
    func removeProduct(id: UUID) { review.products.removeAll { $0.id == id } }

    func startProcessing(pages: [Data]) {
        guard !isProcessing else { return }
        scanTask = Task { await process(pages: pages) }
    }
    func cancelProcessing() { scanTask?.cancel() }

    func process(pages: [Data]) async {
        guard !isProcessing else { return }
        guard !pages.isEmpty else { reportError(ScannerError.noPages); return }
        isProcessing = true
        processingMessage = "Recognising receipt text…"
        hasDraftSession = true
        originalPages = pages
        ocrEvidencePages = []
        pageCount = pages.count
        extractedText = ""
        errorMessage = nil
        extractionWarnings = []
        pipelineDebugReport = "OCR scanning started."
        apply(ReceiptReviewDraft())
        let revision = editRevision
        scheduleSave()
        defer { isProcessing = false; scheduleSave() }

        // Each successful page survives failure on a later page; original JPEGs always survive.
        var recognisedPages: [String] = []
        var hasReadableText = false
        for (index, page) in pages.enumerated() {
            do {
                try Task.checkCancellation()
                let text: String
                if let evidenceRecognizer = recognizer as? any ReceiptEvidenceRecognizing {
                    let evidence = try await evidenceRecognizer.recognizeEvidence(imageData: page)
                    ocrEvidencePages.append(
                        ReceiptOCRPage(pageNumber: index + 1, lines: evidence.lines)
                    )
                    text = evidence.text
                } else {
                    // Existing mock recognizers and shared protocol remain supported.
                    text = try await recognizer.recognize(imageData: page)
                }
                recognisedPages.append("Page \(index + 1)\n\(text)")
                extractedText = recognisedPages.joined(separator: "\n\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasReadableText = true }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    extractionWarnings.append("Page \(index + 1) has no readable text. Refer to its original image.")
                }
            } catch is CancellationError {
                extractionWarnings.append("Processing cancelled. Review the retained OCR and images manually.")
                return
            } catch {
                if Task.isCancelled { return }
                extractionWarnings.append("OCR failed on page \(index + 1). Refer to its original image and add missing products manually.")
            }
        }
        scheduleSave()
        guard hasReadableText else {
            errorMessage = ScannerError.noReadableText.localizedDescription
            return
        }
        processingMessage = "Extracting receipt costs on device…"
        do {
            let result: ReceiptExtractionResult
            if let evidenceExtractor = extractor as? any ReceiptEvidenceExtracting {
                result = try await evidenceExtractor.extract(
                    text: extractedText,
                    evidence: ocrEvidencePages
                )
            } else {
                result = try await extractor.extract(text: extractedText)
            }
            try Task.checkCancellation()
            extractionWarnings += result.reviewWarnings
            #if DEBUG
            var report: [String] = [
                "PIPELINE DIAGNOSTICS (DEBUG ONLY)",
                "OCR length: \(extractedText.count) characters",
                "OCR evidence pages: \(ocrEvidencePages.count)",
                "EXTRACTION RESULT | products: \(result.costBreakdown?.products.count ?? 0)",
                "EXTRACTION RESULT | total: \(result.costBreakdown?.total.map { String(describing: $0) } ?? "nil")",
                "EXTRACTION RESULT | warnings: \(result.reviewWarnings.count)"
            ]
            if let live = extractor as? FoundationModelsReceiptExtractor {
                report.append(contentsOf: await live.debugSnapshot())
            } else {
                report.append("Extractor is a mock or alternate service (no stage trace).")
            }
            pipelineDebugReport = report.joined(separator: "\n")
            #endif
            guard editRevision == revision else {
                extractionWarnings.append("Automatic results were not applied because you edited this review. Your edits have been kept.")
                #if DEBUG
                pipelineDebugReport += "\nNOT APPLIED | user edit revision changed from \(revision) to \(editRevision)"
                #endif
                return
            }
            if let costs = result.costBreakdown { apply(ReceiptReviewDraft(costs)) }
            #if DEBUG
            pipelineDebugReport += "\nREVIEW STATE | products: \(review.products.count) | final total: \(review.total.isEmpty ? "EMPTY" : review.total)"
            #endif
        } catch is CancellationError {
            extractionWarnings.append("Extraction cancelled. Enter costs manually using the retained OCR and images.")
            #if DEBUG
            pipelineDebugReport += "\nEXTRACTION CANCELLED"
            #endif
        } catch {
            extractionWarnings.append("Structured extraction failed. Enter costs manually using the retained OCR and images.")
            #if DEBUG
            pipelineDebugReport += "\nEXTRACTION THREW ERROR | \(error.localizedDescription)"
            #endif
        }
    }

    private func apply(_ draft: ReceiptReviewDraft) {
        applyingExtraction = true
        review = draft
        applyingExtraction = false
    }

    func restoreDraft() async {
        guard !restoreAttempted else { return }
        restoreAttempted = true
        let revision = editRevision
        do {
            guard let snapshot = try await draftStore?.load(),
                  !hasReview, !isProcessing, revision == editRevision else { return }
            hasDraftSession = true
            originalPages = snapshot.pages
            pageCount = snapshot.pages.count
            extractedText = snapshot.rawText
            ocrEvidencePages = snapshot.ocrEvidence ?? []
            extractionWarnings = snapshot.extractionWarnings
            apply(snapshot.review)
        } catch { storageWarning = "The previous review could not be loaded. Its file has not been deleted." }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard draftStore != nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await self?.saveDraft()
        }
    }

    /// Called on background/dismiss as well as after edits. UI never touches the persistence layer.
    func saveDraft() async {
        guard let draftStore, hasReview else { return }
        let snapshot = ReceiptScannerDraftStore.Snapshot(rawText: extractedText, pages: originalPages,
            review: review, extractionWarnings: extractionWarnings,
            ocrEvidence: ocrEvidencePages)
        do {
            try await draftStore.save(snapshot)
            storageWarning = nil
        } catch { storageWarning = "This review could not be saved locally. Keep it open and try again." }
    }

    func reportError(_ error: Error) { errorMessage = error.localizedDescription }
    func reportUnsupportedCamera() { errorMessage = "Document scanning is not available on this device." }
}

