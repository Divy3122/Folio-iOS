import Foundation

/// Reads the printed Subtotal and Final Total without asking AI to classify
/// GST, shipping, discounts, fees or rounding. Product recognition is separate.
enum ReceiptSimpleTotals {
    struct Amounts: Equatable {
        let subtotal: Decimal?
        let total: Decimal?

        /// Signed balancing difference; it is NOT proof of a separately charged fee.
        var additionalFees: Decimal? {
            guard let subtotal, let total else { return nil }
            return total - subtotal
        }
    }

    // These labels must start a line. A description such as "Subtotal (excl. VAT)"
    // may appear between the label and the printed amount.
    private static let subtotalPattern = #"^\s*sub[\s-]*total\b"#

    // Prefer a precise printed total label when more than one TOTAL appears.
    private static let finalTotalLabels = [
        "total amount paid", "grand total", "final total", "total due",
        "amount due", "total paid", "balance due", "amount paid", "total"
    ]

    private static let numberPattern = #"([+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?|[0-9]+(?:[\.,][0-9]{1,2})?))"#
    private static let amountOnlyPattern = #"^\s*(?:AUD|USD|NZD|GBP|EUR)?\s*[$£€¥]?\s*"# + numberPattern + #"\s*$"#

    // Parenthesised text is part of the LABEL, not the value:
    //   Subtotal (excl. VAT): £66,20
    //   Subtotal (incl. GST) $349.00
    // Restrict non-parenthesised qualifiers to tax wording so unrelated numbers,
    // product rows and charges do not accidentally become subtotals.
    private static let qualifierPattern = #"(?:\s*\([^\r\n)]{0,70}\)|\s+(?:(?:excl(?:uding)?|incl(?:uding)?)\.?\s*(?:VAT|GST|tax)))"#

    static func read(ocrText: String) -> Amounts {
        let lines = ocrText.components(separatedBy: .newlines)
        var subtotal: Decimal?
        var total: Decimal?
        var bestTotalPriority = Int.max

        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if subtotal == nil {
                subtotal = labelledAmount(on: line, labelPattern: subtotalPattern)
                    ?? amountOnNextLine(after: line, at: index, in: lines, labelPattern: subtotalPattern)
            }

            for (priority, label) in finalTotalLabels.enumerated() where priority <= bestTotalPriority {
                let labelPattern = #"^\s*"#
                    + label.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
                    + #"\b"#

                if let value = labelledAmount(on: line, labelPattern: labelPattern)
                    ?? amountOnNextLine(after: line, at: index, in: lines, labelPattern: labelPattern) {
                    total = value
                    bestTotalPriority = priority
                    break
                }
            }
        }
        return Amounts(subtotal: subtotal, total: total)
    }

    /// Accept a money amount ONLY after the recognised field label and optional
    /// printed parenthetical qualifiers. Never interpret shipping/GST as subtotal.
    private static func labelledAmount(on line: String, labelPattern: String) -> Decimal? {
        let pattern = labelPattern
            + #"(?:"# + qualifierPattern + #")*\s*[:\-–]?\s*(?:AUD|USD|NZD|GBP|EUR)?\s*[$£€¥]?\s*"#
            + numberPattern + #"\s*$"#
        return matchedAmount(in: line, pattern: pattern)
    }

    /// Some Vision text layouts put the printed amount on the row after its label.
    /// Only consume the next line if it consists exclusively of one money amount.
    private static func amountOnNextLine(after line: String, at index: Int,
                                         in lines: [String], labelPattern: String) -> Decimal? {
        guard index + 1 < lines.count else { return nil }
        let labelOnlyPattern = labelPattern + #"(?:"# + qualifierPattern + #")*\s*[:\-–]?\s*$"#
        guard matches(line, pattern: labelOnlyPattern) else { return nil }
        return matchedAmount(in: lines[index + 1], pattern: amountOnlyPattern)
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func matchedAmount(in text: String, pattern: String) -> Decimal? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return ReceiptAmountParser.printed(String(text[range]))
    }

    /// Only missing names/prices/totals need manual input. No financial analysis.
    static func basicWarnings(for draft: ReceiptReviewDraft) -> [String] {
        var notes: [String] = []
        for (index, product) in draft.products.enumerated() {
            if product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes.append("Product \(index + 1): enter a product name.")
            }
            if ReceiptAmountParser.parse(product.lineTotal) == nil {
                notes.append("Product \(index + 1): enter a valid price.")
            }
        }
        if ReceiptAmountParser.parse(draft.subtotal) == nil {
            notes.append("Enter the printed subtotal.")
        }
        if ReceiptAmountParser.parse(draft.total) == nil {
            notes.append("Enter the printed final total.")
        }
        return notes
    }

    /// Apply this after existing product extraction; disregard model financial
    /// categories. The review computes additional fees as total minus subtotal.
    static func simplify(_ draft: inout ReceiptReviewDraft, ocrText: String) {
        let values = read(ocrText: ocrText)
        draft.subtotal = ReceiptAmountParser.text(values.subtotal)
        draft.total = ReceiptAmountParser.text(values.total)
        draft.discounts = ""
        draft.tax = ""
        draft.fees = ""
        draft.rounding = ""
        draft.taxTreatment = .unknown
        draft.discountTreatment = .unknown
        for index in draft.products.indices {
            draft.products[index].quantity = ""
            draft.products[index].unitPrice = ""
            draft.products[index].discount = ""
        }
    }
}

