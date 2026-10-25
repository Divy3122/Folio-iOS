//
//  ReceiptSimpleBreakdownSections.swift
//  Folio
//
//  Created by Divy Patel on 18/10/2026.
//

import SwiftUI

/// Minimal receipt review: product and printed line price, subtotal, final total,
/// and printed tax/fees. Replaces the two old cost sections; no category guessing.
struct ReceiptSimpleBreakdownSections: View {
    @Binding var review: ReceiptReviewDraft
    let isEditing: Bool

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
                        Text(displayAmount(product.lineTotal))
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

            if isEditing {
                field("Additional fees (including tax)", value: $review.fees)
            } else {
                amountRow("Additional fees (including tax)", value: review.fees)
            }
            Text("Printed tax and fee amounts only; already included in the receipt total where applicable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !isEditing {
                amountRow("Final total", value: review.total)
            }
        }
    }

    private func displayAmount(_ text: String) -> String {
        guard let amount = ReceiptAmountParser.parse(text) else {
            return text.isEmpty ? "Not readable" : text
        }
        return amount.formatted(.number.precision(.fractionLength(2)))
    }

    private func amountRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(displayAmount(value))
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
