import Foundation

/// Copies printed summaries independently. Never balances receipt arithmetic.
enum ReceiptSimpleTotals {
    struct Amounts: Equatable {
        let subtotal: Decimal?
        let total: Decimal?

        var tax: Decimal? = nil
        var fees: Decimal? = nil
        var hasConflictingTotals = false
        var hasConflictingSubtotals = false
        var additionalFees: Decimal? {
            guard tax != nil || fees != nil else { return nil }
            return (tax ?? 0) + (fees ?? 0)
        }

    }

    // These labels must start a line. A description such as "Subtotal (excl. VAT)"
    // may appear between the label and the printed amount.
    private static let subtotalPattern = #"^\s*sub[\s-]*total\b"#

    // Recognise printed total labels; distinct values remain unresolved.
    private static let finalTotalLabels = [
        "total amount paid", "grand total", "final total", "total due",
        "amount due", "total paid", "balance due", "amount paid", "total"
    ]

    // Copy printed charges only. Included tax is displayed as receipt information,
    // never added to the printed final total. Percentage qualifiers are not amounts.
    private static let chargePattern = #"^\s*(?:(?:includes?|included)\s+)?(?:GST|VAT|(?:sales\s+)?tax|shipping|delivery|service(?:\s+charge)?|surcharge|bag\s+fee|additional\s+fees?)\b(?:\s+[0-9]+(?:[.,][0-9]+)?%?(?=\s+[$£€¥+-]?[0-9]))?"#

    private static let numberPattern = #"([+-]?(?:[0-9]{1,3}(?:[.,][0-9]{3})+[.,][0-9]{1,2}|[0-9]+(?:[.,][0-9]{1,2})?))"#
    private static let amountOnlyPattern = #"^\s*(?:A\$|AUD|USD|NZD|GBP|EUR|CAD|CHF|JPY)?\s*[$£€¥]?\s*"# + numberPattern + #"\s*$"#

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
        var printedTaxes: [Decimal] = []
        var printedFees: [Decimal] = []
        var totalValues: [Decimal] = []
        var subtotalValues: [Decimal] = []

        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if let value = labelledAmount(on: line, labelPattern: subtotalPattern)
                ?? amountOnNextLine(after: line, at: index, in: lines, labelPattern: subtotalPattern) {
                subtotalValues.append(value)
            }

            if let charge = labelledAmount(on: line, labelPattern: chargePattern)
                ?? amountOnNextLine(after: line, at: index, in: lines, labelPattern: chargePattern) {
                if matches(line, pattern: #"^\s*(?:(?:includes?|included)\s+)?(?:GST|VAT|(?:sales\s+)?tax)\b"#) {
                    printedTaxes.append(charge)
                } else { printedFees.append(charge) }
            }

            if let included = matchedAmount(in: line,
                pattern: #"^\s*includes?\s+(?:A\$|AUD|USD|NZD|GBP|EUR|CAD|CHF|JPY)?\s*[$£€¥]?\s*"# + numberPattern + #"\s+(?:GST|VAT|tax)\s*$"#) {
                printedTaxes.append(included)
            }

            for label in finalTotalLabels {
                let labelPattern = #"^\s*"#
                    + label.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
                    + #"\b"#

                if let value = labelledAmount(on: line, labelPattern: labelPattern)
                    ?? amountOnNextLine(after: line, at: index, in: lines, labelPattern: labelPattern) {
                    totalValues.append(value)
                    break
                }
            }
        }
        subtotal = Set(subtotalValues).count == 1 ? subtotalValues.first : nil
        total = Set(totalValues).count == 1 ? totalValues.first : nil
        return Amounts(subtotal: subtotal, total: total,
                       tax: printedTaxes.isEmpty ? nil : printedTaxes.reduce(0, +),
                       fees: printedFees.isEmpty ? nil : printedFees.reduce(0, +),
                       hasConflictingTotals: Set(totalValues).count > 1,
                       hasConflictingSubtotals: Set(subtotalValues).count > 1)
    }

    /// Accept a money amount ONLY after the recognised field label and optional
    /// printed parenthetical qualifiers. Never interpret shipping/GST as subtotal.
    private static func labelledAmount(on line: String, labelPattern: String) -> Decimal? {
        let pattern = labelPattern
            + #"(?:"# + qualifierPattern + #")*\s*[:–]?\s*(?:A\$|AUD|USD|NZD|GBP|EUR|CAD|CHF|JPY)?\s*[$£€¥]?\s*"#
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
        if !draft.fees.isEmpty, ReceiptAmountParser.parse(draft.fees) == nil {
            notes.append("Enter a valid printed tax/fee amount.")
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
    /// categories. Only explicitly printed tax and fee components are combined.
    static func simplify(_ draft: inout ReceiptReviewDraft, ocrText: String, allowTotalFallback: Bool = true) {
        let values = read(ocrText: ocrText)
        if ReceiptAmountParser.parse(draft.subtotal) == nil {
            draft.subtotal = ReceiptAmountParser.text(values.subtotal)
        }
        if allowTotalFallback, ReceiptAmountParser.parse(draft.total) == nil {
            draft.total = ReceiptAmountParser.text(values.total)
        }
        let printedTax = ReceiptAmountParser.parse(draft.tax) ?? values.tax
        let printedFees = ReceiptAmountParser.parse(draft.fees) ?? values.fees
        if printedTax != nil || printedFees != nil {
            draft.fees = ReceiptAmountParser.text((printedTax ?? 0) + (printedFees ?? 0))
        } else {
            draft.fees = ReceiptAmountParser.text(values.additionalFees)
        }
        draft.discounts = ""
        draft.tax = ""
        draft.rounding = ""
        draft.taxTreatment = .unknown
        draft.discountTreatment = .unknown

    }
}

