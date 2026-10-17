import Foundation

/// An untrusted suggestion from Apple Intelligence, anchored to a physical OCR line.
/// A semantic role is proposed by the model; the numeric value must come from OCR.
struct ReceiptSemanticAmountProposal: Sendable {
    enum Role: Sendable {
        case finalTotal
        case subtotal
        case tax
        case other
    }

    var role: Role
    var sourceLine: Int
    var printedAmount: String
    var evidence: String? = nil
}

/// Generic evidence verifier: does not inspect retailer names or hard-code total labels.
/// Missing and conflicting values stay unresolved rather than being calculated.
enum ReceiptSemanticTotalVerifier {
    struct Verified: Sendable {
        var total: Decimal?
        var subtotal: Decimal?
        var tax: Decimal?
        var hasConflictingTotals: Bool = false
    }

    private static let monetaryToken = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])((?:(?:A\$|AUD|USD|NZD|EUR|GBP|CAD|CHF|[$£€¥])\s*)?[+-]?[0-9]{1,9}(?:[.,][0-9]{3})*[.,][0-9]{2})(?![\p{L}\p{N}])"#,
        options: [.caseInsensitive]
    )

    private static func amounts(in line: String) -> [Decimal] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return monetaryToken.matches(in: line, range: range).compactMap { match in
            guard let tokenRange = Range(match.range(at: 1), in: line) else { return nil }
            return ReceiptAmountParser.printed(String(line[tokenRange]))
        }
    }

    /// A two-line OCR observation is allowed only when the second line contains
    /// nothing but a printed price (and optionally a currency symbol).
    private static func amountOnly(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amounts(in: trimmed).count == 1,
              let match = monetaryToken.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
              ),
              match.range.location == 0,
              match.range.length == (trimmed as NSString).length else { return nil }
        return amounts(in: trimmed).first
    }

    static func verify(
        _ proposals: [ReceiptSemanticAmountProposal],
        against rawText: String
    ) -> Verified {
        let lines = rawText.components(separatedBy: .newlines)
        var totalValues: [Decimal] = []
        var subtotalValues: [Decimal] = []
        var taxValues: [Decimal] = []

        for proposal in proposals {
            var offset = proposal.sourceLine - 1
            guard let proposed = ReceiptAmountParser.printed(proposal.printedAmount) else {
                continue
            }

            if let evidence = proposal.evidence, !evidence.isEmpty {
                func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
                let quote = key(evidence)
                let matches = lines.indices.filter { index in
                    var context = lines[index]
                    if index + 1 < lines.count, amountOnly(lines[index + 1]) != nil { context += lines[index + 1] }
                    return !quote.isEmpty && key(context).contains(quote)
                }
                if !matches.contains(offset) {
                    guard matches.count == 1 else { continue }
                    offset = matches[0]
                }
            }
            guard lines.indices.contains(offset) else { continue }
            let matched = amounts(in: lines[offset]).contains(proposed) ||
                (offset + 1 < lines.count && amountOnly(lines[offset + 1]) == proposed)
            guard matched else { continue }

            switch proposal.role {
            case .finalTotal: totalValues.append(proposed)
            case .subtotal: subtotalValues.append(proposed)
            case .tax: taxValues.append(proposed)
            case .other: break
            }
        }

        func singleValue(_ values: [Decimal]) -> Decimal? {
            guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        return Verified(
            total: singleValue(totalValues),
            subtotal: singleValue(subtotalValues),
            tax: singleValue(taxValues),
            hasConflictingTotals: Set(totalValues).count > 1
        )
    }

    /// Only fill missing fields. Never overwrite an accepted value or turn
    /// conflicting printed totals into a guessed value.
    static func apply(
        _ verified: Verified,
        to original: ReceiptExtractionResult
    ) -> ReceiptExtractionResult {
        var result = original
        var costs = result.costBreakdown ?? ReceiptCostBreakdown()

        // Earlier overlapping chunks may already have found conflicting totals.
        let priorConflict = result.reviewWarnings.contains {
            $0.localizedCaseInsensitiveContains("conflicting final total")
        }
        if verified.hasConflictingTotals {
            result.reviewWarnings.append(
                "Conflicting printed final-total candidates require review."
            )
        } else if !priorConflict && costs.total == nil {
            costs.total = verified.total
        }
        costs.subtotal = costs.subtotal ?? verified.subtotal
        costs.tax = costs.tax ?? verified.tax
        result.costBreakdown = costs
        result.reviewWarnings = Array(Set(result.reviewWarnings)).sorted()
        return result
    }
}
