import SwiftUI

/// Exactly two primary sections; references and warnings belong to Total Cost.
struct ReceiptCostReviewView: View {
    @Bindable var viewModel: ReceiptScannerViewModel
    var isEditing = false

    private var actionableNotes: [String] {
        ReceiptReviewAttention.notes(for: viewModel.review,
                                     extractionWarnings: viewModel.extractionWarnings)
    }

    var body: some View {
        Form {
            Section("Individual Product Cost Breakdown") {
                if isEditing {
                if viewModel.review.products.isEmpty {
                    Text("No products yet. Add products from the receipt; leave unreadable fields blank.")
                        .foregroundStyle(.secondary)
                }
                ForEach($viewModel.review.products) { $product in
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Product name", text: $product.name, axis: .vertical)
                            .font(.headline)
                            .accessibilityLabel("Product name")
                        numberField("Quantity", text: $product.quantity)
                        numberField("Unit price", text: $product.unitPrice)
                        numberField("Product discount", text: $product.discount)
                        numberField("Final line-item cost", text: $product.lineTotal)
                        Toggle("Returned product", isOn: $product.isReturn)
                        Button("Remove product", role: .destructive) {
                            viewModel.removeProduct(id: product.id)
                        }
                        .accessibilityLabel("Remove \(product.name.isEmpty ? "unnamed product" : product.name)")
                    }
                    .padding(.vertical, 6)
                }
                Button(action: viewModel.addProduct) {
                    Label("Add product", systemImage: "plus.circle")
                }
                } else {
                    if viewModel.review.products.isEmpty {
                        Text("No product costs could be extracted. Choose Edit to enter them from the original receipt.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.review.products) { product in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(product.name.isEmpty ? "Unnamed product" : product.name).font(.headline)
                            if !product.quantity.isEmpty { resultRow("Quantity", value: product.quantity) }
                            if !product.unitPrice.isEmpty { resultRow("Unit price", value: product.unitPrice) }
                            if !product.discount.isEmpty { resultRow("Product discount", value: product.discount) }
                            resultRow("Final line-item cost", value: product.lineTotal)
                            if product.isReturn { Text("Returned product").foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            Section("Total Cost") {
                if isEditing {
                numberField("Subtotal", text: $viewModel.review.subtotal)
                numberField("Discounts", text: $viewModel.review.discounts)
                Picker("Discount treatment", selection: $viewModel.review.discountTreatment) {
                    Text("Not confirmed").tag(ReceiptCostBreakdown.DiscountTreatment.unknown)
                    Text("Included in line costs").tag(ReceiptCostBreakdown.DiscountTreatment.includedInLines)
                    Text("Deduct from line costs").tag(ReceiptCostBreakdown.DiscountTreatment.deductedFromLines)
                }
                numberField("GST / tax", text: $viewModel.review.tax)
                Picker("Tax treatment", selection: $viewModel.review.taxTreatment) {
                    Text("Not confirmed").tag(ReceiptCostBreakdown.TaxTreatment.unknown)
                    Text("Already included").tag(ReceiptCostBreakdown.TaxTreatment.included)
                    Text("Added separately").tag(ReceiptCostBreakdown.TaxTreatment.added)
                }
                numberField("Additional fees", text: $viewModel.review.fees)
                numberField("Rounding adjustment", text: $viewModel.review.rounding)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Final total paid").font(.headline)
                    TextField("Missing — enter printed total", text: $viewModel.review.total)
                        .font(.title.bold())
                        .keyboardType(.numbersAndPunctuation)
                        .accessibilityLabel("Final total paid")
                    Text("Use the receipt's printed total. It is never replaced by the product sum.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Amounts are in the receipt's currency. Use a decimal point; leave unknown values blank. For returns, enter a negative line cost.")
                    .font(.footnote).foregroundStyle(.secondary)
                } else {
                    if !viewModel.review.subtotal.isEmpty { resultRow("Subtotal", value: viewModel.review.subtotal) }
                    if !viewModel.review.discounts.isEmpty { resultRow("Discounts", value: viewModel.review.discounts) }
                    if !viewModel.review.tax.isEmpty {
                        resultRow(taxLabel, value: viewModel.review.tax)
                    }
                    if !viewModel.review.fees.isEmpty { resultRow("Additional fees", value: viewModel.review.fees) }
                    if !viewModel.review.rounding.isEmpty { resultRow("Rounding adjustment", value: viewModel.review.rounding) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Final total paid").font(.headline)
                        Text(viewModel.review.total.isEmpty ? "Not readable" : viewModel.review.total)
                            .font(.largeTitle.bold()).textSelection(.enabled)
                        Text("Amounts are in the receipt's currency. Choose Edit to correct any extracted information.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if viewModel.isProcessing {
                    ProgressView(viewModel.processingMessage)
                        .accessibilityAddTraits(.updatesFrequently)
                    Button("Stop processing", role: .cancel, action: viewModel.cancelProcessing)
                }
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                // ReceiptSure-inspired attention UX: show only errors that require
                // user action. Retain every AI evidence warning in a separate log.
                if !actionableNotes.isEmpty {
                    DisclosureGroup {
                        ForEach(actionableNotes, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 3)
                        }
                    } label: {
                        Label("Needs review (\(actionableNotes.count))",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !viewModel.extractionWarnings.isEmpty {
                    DisclosureGroup("Extraction details") {
                        Text("These are diagnostic messages from OCR and Apple Intelligence, not all corrections you need to make.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(Set(viewModel.extractionWarnings)).sorted(), id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Check extracted values against your receipt before saving.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Original OCR text") {
                    Text(viewModel.extractedText.isEmpty ? "No readable OCR text. Refer to the original scans." : viewModel.extractedText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                DisclosureGroup("Original scans (\(viewModel.pageCount) pages)") {
                    ForEach(viewModel.originalPages.indices, id: \.self) { index in
                        if let image = UIImage(data: viewModel.originalPages[index]) {
                            Image(uiImage: image)
                                .resizable().scaledToFit()
                                .accessibilityLabel("Original receipt page \(index + 1)")
                        }
                    }
                }
                if let warning = viewModel.storageWarning {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    Button("Retry saving draft") { Task { await viewModel.saveDraft() } }
                }
                Text("This review and its originals are saved locally on this device. Starting a new scan replaces the draft; it does not save a receipt to the library.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var taxLabel: String {
        switch viewModel.review.taxTreatment {
        case .included: "VAT / GST / tax (included)"
        case .added: "VAT / GST / tax (added separately)"
        case .unknown: "VAT / GST / tax (treatment unconfirmed)"
        }
    }

    private func resultRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "Not readable" : value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField("Not available", text: text)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel(title)
        }
    }
}

#Preview {
    ReceiptCostReviewView(viewModel: ReceiptScannerViewModel(draftStore: nil))
}
