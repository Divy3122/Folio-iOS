//
//  ReceiptSimpleBreakdownSections.swift
//  Folio
//
//  Created by Divy Patel on 18/10/2026.
//

import SwiftUI

/// Minimal receipt review: product and printed line price, subtotal, final total,
/// and the difference. Replaces the two old cost sections; no category guessing.
struct ReceiptSimpleBreakdownSections: View {
    @Binding var review: ReceiptReviewDraft
    let isEditing: Bool

    private var additionalFees: String? {
        guard let subtotal = ReceiptAmountParser.parse(review.subtotal),
              let total = ReceiptAmountParser.parse(review.total) else { return nil }
        return ReceiptAmountParser.text(total - subtotal)
    }

    var body: some View {
        Section("Individual Product Cost Breakdown") {
            if review.products.isEmpty {
                Text("No products found. Choose Edit to enter them manually.")
                    .foregroundStyle(.secondary)
            }
            if isEditing {
                ForEach($review.products) { $product in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Product name", text: $product.name, axis: .vertical)
                            .font(.headline)
                        TextField("Product price", text: $product.lineTotal)
                            .keyboardType(.numbersAndPunctuation)
                        Button("Remove product", role: .destructive) {
                            review.products.removeAll { $0.id == product.id }
                        }
                    }
                    .padding(.vertical, 5)
                }
                Button("Add product", systemImage: "plus.circle") {
                    review.products.append(.init())
                }
            } else {
                ForEach(review.products) { product in
                    LabeledContent(product.name.isEmpty ? "Unnamed product" : product.name) {
                        Text(product.lineTotal.isEmpty ? "Not readable" : product.lineTotal)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        Section("Total Cost") {
            if isEditing {
                field("Subtotal", value: $review.subtotal)
                field("Final total", value: $review.total)
            } else {
                amountRow("Subtotal", value: review.subtotal)
            }

            if let additionalFees {
                amountRow("Additional fees", value: additionalFees)
            } else {
                Text("Additional fees will appear when subtotal and total are available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !isEditing {
                amountRow("Final total", value: review.total)
            }
        }
    }

    private func amountRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value.isEmpty ? "Not readable" : value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func field(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            TextField(label, text: value)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel(label)
        }
    }
}
