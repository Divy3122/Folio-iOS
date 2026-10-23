import SwiftUI

/// Receipt review stays deliberately simple:
/// manual retailer/date, product names + prices, subtotal, the total-minus-subtotal
/// adjustment, and the final total. The scanner's original evidence remains accessible.
struct ReceiptCostReviewView: View {
    @Bindable var viewModel: ReceiptScannerViewModel
    var isEditing = false

    var body: some View {
        Form {
            // Exactly the two requested financial sections. Additional fees are
            // calculated in this component as final total minus subtotal.
            ReceiptSimpleBreakdownSections(
                review: $viewModel.review,
                isEditing: isEditing
            )

            Section("Receipt Reference") {
                if viewModel.isProcessing {
                    ProgressView(viewModel.processingMessage)
                        .accessibilityAddTraits(.updatesFrequently)
                    Button("Stop processing", role: .cancel, action: viewModel.cancelProcessing)
                }

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                let accuracyNotes = Array(Set(viewModel.extractionWarnings)).sorted()
                if !accuracyNotes.isEmpty {
                    DisclosureGroup("Scan accuracy checks (\(accuracyNotes.count))") {
                        ForEach(accuracyNotes, id: \.self) { note in
                            Label(note, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Missing product names or printed totals are still actionable.
                // We do not show the extractor's tax/discount/fee guesses as warnings.
                if !viewModel.warnings.isEmpty {
                    DisclosureGroup("Missing information (\(viewModel.warnings.count))") {
                        ForEach(viewModel.warnings, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                DisclosureGroup("Original OCR text") {
                    Text(viewModel.extractedText.isEmpty
                         ? "No readable OCR text. Refer to the original scans."
                         : viewModel.extractedText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }

                DisclosureGroup("Original scans (\(viewModel.pageCount) pages)") {
                    ForEach(viewModel.originalPages.indices, id: \.self) { index in
                        if let image = UIImage(data: viewModel.originalPages[index]) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel("Original receipt page \(index + 1)")
                        }
                    }
                }

                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-FolioScannerDiagnostics") {
                    DisclosureGroup("Debug pipeline report (test builds only)") {
                        if !viewModel.extractionWarnings.isEmpty {
                            DisclosureGroup("Extraction diagnostics (\(Set(viewModel.extractionWarnings).count))") {
                                ForEach(Array(Set(viewModel.extractionWarnings)).sorted(), id: \.self) { warning in
                                    Text(warning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        let report = viewModel.pipelineDebugReport
                        Text(report)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        ShareLink(item: report) {
                            Label("Share diagnostics", systemImage: "square.and.arrow.up")
                        }
                        Text("Diagnostics may include receipt contents. Redact personal information before sharing.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

                if let warning = viewModel.storageWarning {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    Button("Retry saving draft") {
                        Task { await viewModel.saveDraft() }
                    }
                }

                Text("Check the product prices, subtotal and final total against your original receipt before saving.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("This review and its original scans are saved as a local draft. Starting a new scan replaces the draft; it does not save a receipt to your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

#Preview {
    ReceiptCostReviewView(viewModel: ReceiptScannerViewModel(draftStore: nil))
}

