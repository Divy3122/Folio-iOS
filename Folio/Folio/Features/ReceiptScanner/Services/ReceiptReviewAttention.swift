import Foundation

/// User-facing, actionable review issues. Raw model evidence warnings remain
/// available separately as diagnostics, but are not treated as accounting errors.
enum ReceiptReviewAttention {
    static func notes(for draft: ReceiptReviewDraft, extractionWarnings: [String]) -> [String] {
        let validation = ReceiptCostValidator.warnings(for: draft)
        let hasMissingLineCost = draft.products.contains { ReceiptAmountParser.parse($0.lineTotal) == nil }
        var notes: [String] = []

        for message in validation {
            if hasMissingLineCost && message.hasPrefix("Total cannot be fully reconciled until") {
                // Consequence of the missing price, not a second problem.
                continue
            }
            if let match = message.range(of: #"^Product ([0-9]+) has a missing or unreadable line cost\.$"#,
                                         options: .regularExpression),
               let digits = message[match].split(separator: " ").dropFirst().first,
               let number = Int(digits), draft.products.indices.contains(number - 1) {
                let name = draft.products[number - 1].name
                notes.append("\(name.isEmpty ? "Product \(number)" : name): verify the printed line-item cost.")
            } else {
                notes.append(message)
            }
        }

        // Truly operational failures deserve attention; optional AI evidence
        // failures (missing unit price/discount/quantity) do not.
        for warning in extractionWarnings {
            let lower = warning.lowercased()
            if lower.contains("ocr failed") ||
               lower.contains("no readable text") ||
               lower.contains("automatic extraction failed") ||
               lower.contains("processing cancelled") ||
               lower.contains("extraction cancelled") ||
               lower.contains("conflicting") ||
               lower.contains("overlapping ocr produced") ||
               lower.contains("automatic results were not applied") {
                notes.append(warning)
            }
        }
        return Array(Set(notes)).sorted()
    }
}
