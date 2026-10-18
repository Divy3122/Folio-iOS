import SwiftUI
import UIKit

struct ReceiptDetailView: View {
    let record: ReceiptRecord
    let services: ReceiptLibraryServices

    @State private var pageImage: UIImage?
    @State private var imageMissing = false

    private var receipt: PurchaseReceipt { record.receipt }

    private func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: receipt.currencyCode))
    }

    private var costRows: [(label: String, value: Decimal)] {
        let rows: [(String, Decimal?)] = [
            ("Subtotal", record.costs?.subtotal),
            ("Discounts", record.costs?.discounts),
            ("GST / tax", record.costs?.tax),
            ("Fees", record.costs?.fees),
            ("Rounding", record.costs?.rounding)
        ]
        return rows.compactMap { label, value in value.map { (label, $0) } }
    }

    private var hasDetails: Bool {
        !record.metadata.category.isEmpty || !record.metadata.tags.isEmpty || !record.metadata.notes.isEmpty
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Retailer", value: receipt.retailer.name)
                LabeledContent("Date", value: receipt.purchasedAt.formatted(date: .long, time: .omitted))
                LabeledContent("Profile", value: receipt.profile.rawValue.capitalized)
                LabeledContent("Total", value: money(receipt.total))
            }

            if !receipt.items.isEmpty {
                Section("Items") {
                    ForEach(receipt.items) { item in
                        LabeledContent(item.quantity > 1 ? "\(item.name) × \(item.quantity)" : item.name,
                                       value: money(item.unitPrice * Decimal(item.quantity)))
                    }
                }
            }

            if !costRows.isEmpty {
                Section("Cost breakdown") {
                    ForEach(costRows, id: \.label) { row in
                        LabeledContent(row.label, value: money(row.value))
                    }
                }
            }

            if hasDetails {
                Section("Details") {
                    if !record.metadata.category.isEmpty {
                        LabeledContent("Category", value: record.metadata.category)
                    }
                    if !record.metadata.tags.isEmpty {
                        LabeledContent("Tags", value: record.metadata.tags.joined(separator: ", "))
                    }
                    if !record.metadata.notes.isEmpty {
                        Text(record.metadata.notes)
                    }
                }
            }

            if record.metadata.imageCount > 0 {
                Section("Scanned receipt") {
                    if let pageImage {
                        Image(uiImage: pageImage)
                            .resizable()
                            .scaledToFit()
                            .accessibilityLabel("Scanned receipt, page 1")
                    } else if imageMissing {
                        Label("The scanned image is unavailable.", systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle(receipt.retailer.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { loadFirstPage() }
    }

    private func loadFirstPage() {
        guard record.metadata.imageCount > 0 else { return }
        if let data = try? services.images.loadPage(0, for: record.id), let image = UIImage(data: data) {
            pageImage = image
        } else {
            imageMissing = true
        }
    }
}
