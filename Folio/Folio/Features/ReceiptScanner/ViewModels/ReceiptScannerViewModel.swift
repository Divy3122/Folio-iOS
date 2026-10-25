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

    private(set) var companyReview = CompanyReview()
    private(set) var availableCompanies: [Company] = []
    private(set) var companyDebugReport = ""
    private(set) var companyMessage: String?
    private(set) var identifyingCompany = false
    private(set) var confirmingCompany = false
    private(set) var historicalReceipts: [PurchaseReceipt] = []
    @ObservationIgnored private let companyIdentifier: (any ReceiptCompanyIdentifying)?
    @ObservationIgnored private let companyRepository: (any CompanyRepository)?
    @ObservationIgnored private let receiptRepository: (any ReceiptRepository)?
    @ObservationIgnored private var companyTask: Task<Void, Never>?
    @ObservationIgnored private var companyRevision = 0
    @ObservationIgnored private var searchRevision = 0

    func editCompanyName(_ name: String) {
        companyRevision += 1
        identifyingCompany = false
        companyReview = CompanyReview(name: name, status: .suggested, message: "Manual retailer — confirm to link.")
        hasDraftSession = true
        scheduleSave()
    }
    func selectCompany(_ company: Company) {
        guard company.confirmed else { proposeCompany(company); return }
        companyRevision += 1
        identifyingCompany = false
        companyReview = CompanyReview(name: company.name, company: company, status: .confirmed, message: "Retailer confirmed for this receipt.")
        hasDraftSession = true
        scheduleSave()
    }
    func proposeCompany(_ company: Company) {
        companyRevision += 1
        identifyingCompany = false
        companyReview = CompanyReview(name: company.name, company: company, status: .suggested, message: "Confirm this receipt issuer.")
        scheduleSave()
    }
    func confirmCompany() async {
        guard !confirmingCompany else { return }
        confirmingCompany = true
        defer { confirmingCompany = false }
        companyRevision += 1
        identifyingCompany = false
        let revision = companyRevision
        let proposal = companyReview.company ?? Company(name: companyReview.name)
        guard let companyRepository else { companyMessage = "Company storage is unavailable."; return }
        do {
            let company = try await ConfirmCompany(repository: companyRepository)(proposal)
            guard revision == companyRevision else { return }
            selectCompany(company)
            await loadCompanies()
        } catch { companyMessage = "Retailer could not be saved. Select an existing identity or try again." }
    }
    func loadCompanies() async {
        do {
            availableCompanies = try await companyRepository?.fetchAll() ?? []
            if companyReview.status == .confirmed, let latest = availableCompanies.first(where: { $0.id == companyReview.company?.id }) {
                companyReview.company = latest
            }
        }
        catch { companyMessage = "Saved retailers could not be loaded." }
    }
    func searchPurchases(_ query: String) async {
        guard let receiptRepository, let companyRepository else { return }
        searchRevision += 1
        let revision = searchRevision
        do {
            let results = try await SearchCompanyPurchases(receipts: receiptRepository, companies: companyRepository)(query)
            guard revision == searchRevision, !Task.isCancelled else { return }
            historicalReceipts = results
        }
        catch { companyMessage = "Saved purchases could not be searched." }
    }
    /// The permanent receipt editor calls this before its existing SaveReceipt use case.
    func associateCompany(with receipt: PurchaseReceipt) throws -> PurchaseReceipt {
        guard companyReview.status == .confirmed, let company = companyReview.company else { return receipt }
        return try AssociateReceiptCompany()(receipt, company: company)
    }
    private func resetCompany() {
        companyTask?.cancel()
        companyRevision += 1
        companyReview = CompanyReview()
        companyMessage = nil
        companyDebugReport = ""
        identifyingCompany = false
    }
    private func startCompanyIdentification() {
        guard let companyIdentifier else { return }
        let revision = companyRevision
        let text = extractedText
        let pages = ocrEvidencePages
        identifyingCompany = true
        companyTask = Task { [weak self] in
            guard let self else { return }
            await loadCompanies()
            var proposals: [Company] = []
            do { proposals = try await companyIdentifier.identify(text: text, pages: pages) }
            catch { if revision == companyRevision { companyMessage = "Retailer identification unavailable. Select or enter a retailer." } }
            guard revision == companyRevision, !Task.isCancelled else { return }
            if proposals.isEmpty { proposals = CompanyMatching.offline(text: text, records: availableCompanies) }
            companyReview = CompanyMatching.review(proposals, records: availableCompanies)
            #if DEBUG
            let trace = await (companyIdentifier as? ReceiptCompanyIdentifier)?.debugSnapshot() ?? []
            guard revision == companyRevision, !Task.isCancelled else { return }
            companyDebugReport = (trace + ["Company match: \(companyReview.status.rawValue); records: \(availableCompanies.count)",
                "Review retailer: \(companyReview.name.isEmpty ? "Unknown Retailer" : companyReview.name)"]).joined(separator: "\n")
            #endif
            identifyingCompany = false
            scheduleSave()
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
         draftStore: ReceiptScannerDraftStore? = .live(),
         companyIdentifier: (any ReceiptCompanyIdentifying)? = nil,
         companies: (any CompanyRepository)? = nil,
         receipts: (any ReceiptRepository)? = nil) {
        self.recognizer = recognizer
        self.extractor = extractor
        self.draftStore = draftStore
        self.companyIdentifier = companyIdentifier
        self.companyRepository = companies
        self.receiptRepository = receipts
    }

    // The simplified review only asks for product names/prices and printed totals.
    // Model guesses about tax, shipping, fees or discounts are not user-facing warnings.
    var warnings: [String] { ReceiptSimpleTotals.basicWarnings(for: review) }
    var hasReview: Bool { hasDraftSession || !originalPages.isEmpty || !extractedText.isEmpty || !review.products.isEmpty }

    func beginManualReceipt() {
        guard !isProcessing else { return }
        resetCompany()
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
        resetCompany()
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
        // The store name and receipt date are entered manually in Receipt Review.
        // Do not make a second AI call to identify the company.
        processingMessage = "Extracting receipt products on device…"
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
            // Retain the existing product extraction, but ignore AI-generated
            // financial arithmetic. Preserve copied totals and printed charges.
            var draft: ReceiptReviewDraft
            if let costs = result.costBreakdown {
                draft = ReceiptReviewDraft(costs)
            } else {
                draft = ReceiptReviewDraft()
            }
            let conflictingTotals = result.reviewWarnings.contains {
                $0.localizedCaseInsensitiveContains("conflicting") && $0.localizedCaseInsensitiveContains("total")
            }
            ReceiptSimpleTotals.simplify(&draft, ocrText: extractedText, allowTotalFallback: !conflictingTotals)
            let audit = ReceiptScanQualityAudit.inspect(
                text: extractedText, pages: ocrEvidencePages, expectedPageCount: pageCount
            )
            extractionWarnings.append(contentsOf: audit.warnings)
            ReceiptScanQualityAudit.protect(&draft, audit: audit)
            apply(draft)
            #if DEBUG
            let simpleAmounts = ReceiptSimpleTotals.read(ocrText: extractedText)
            pipelineDebugReport += "\nSIMPLE TOTALS | printed subtotal: \(simpleAmounts.subtotal.map { String(describing: $0) } ?? "missing") | printed total: \(simpleAmounts.total.map { String(describing: $0) } ?? "missing") | printed tax/fees: \(simpleAmounts.additionalFees.map { String(describing: $0) } ?? "missing")"
            pipelineDebugReport += "\nREVIEW STATE | products: \(review.products.count) | subtotal: \(review.subtotal.isEmpty ? "EMPTY" : review.subtotal) | final total: \(review.total.isEmpty ? "EMPTY" : review.total)"
            #endif
        } catch is CancellationError {
            extractionWarnings.append("Extraction cancelled. Enter costs manually using the retained OCR and images.")
            #if DEBUG
            pipelineDebugReport += "\nEXTRACTION CANCELLED"
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            extractionWarnings.append("Structured product extraction failed. Check products against the retained images.")
            var fallback = ReceiptReviewDraft()
            ReceiptSimpleTotals.simplify(&fallback, ocrText: extractedText)
            let audit = ReceiptScanQualityAudit.inspect(
                text: extractedText, pages: ocrEvidencePages, expectedPageCount: pageCount
            )
            extractionWarnings.append(contentsOf: audit.warnings)
            ReceiptScanQualityAudit.protect(&fallback, audit: audit)
            if editRevision == revision { apply(fallback) }
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
            companyReview = snapshot.company ?? CompanyReview()
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
            ocrEvidence: ocrEvidencePages, company: companyReview)
        do {
            try await draftStore.save(snapshot)
            storageWarning = nil
        } catch { storageWarning = "This review could not be saved locally. Keep it open and try again." }
    }

    func reportError(_ error: Error) { errorMessage = error.localizedDescription }
    func reportUnsupportedCamera() { errorMessage = "Document scanning is not available on this device." }
}


