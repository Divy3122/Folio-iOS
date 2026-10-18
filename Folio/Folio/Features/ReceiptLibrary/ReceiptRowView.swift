import SwiftUI

struct ReceiptRowView: View {
    let record: ReceiptRecord

    private var receipt: PurchaseReceipt { record.receipt }

    private var detail: String? {
        let parts = ([record.metadata.category] + record.metadata.tags).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.retailer.name)
                    .font(.headline)
                Text(receipt.purchasedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(receipt.total.formatted(.currency(code: receipt.currencyCode)))
                    .font(.headline)
                    .monospacedDigit()
                if receipt.profile == .business {
                    Label("Business", systemImage: "briefcase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
