import Foundation

/// A suggestion from the *focused* Apple Intelligence pass, not trusted receipt data.
/// The verifier requires matching original OCR before using any of its fields.
struct FocusedReceiptProductProposal: Sendable {
    var sourceLine: Int
    var name: String
    var quantity: String?
    var lineTotal: String?
    var evidence: String
}

/// Row purpose is checked before numeric evidence, across both extraction passes.
/// Punctuation differences in generic receipt field names do not make them products.
enum ReceiptOCRRowKind {
    case product, financialSummary, paymentMetadata, heading, other

    private static let summaries = [
        "SUB TOTAL", "SUBTOTAL", "TOTAL", "GRAND TOTAL", "VAT", "GST", "TAX",
        "DISCOUNT", "SAVING", "ROUNDING", "FEE", "SURCHARGE", "BALANCE",
        "AMOUNT DUE", "AMOUNT PAID", "TIP", "GRATUITY", "SERVICE", "DELIVERY",
        "SHIPPING", "DONATION"
    ]
    private static let payments = [
        "PAYMENT", "PAID", "CASH", "CHANGE", "TENDER", "VISA", "MASTERCARD", "DEBIT",
        "CREDIT", "EFTPOS", "AUTH", "LOYALTY", "REWARD", "POINTS", "TRANSACTION"
    ]
    private static let otherFields = [
        "DATE", "TIME", "TABLE", "SERVER", "PHONE", "TEL", "RECEIPT", "INVOICE",
        "PAGE", "ORDER NO", "VAT NO", "VAT REG", "ABN", "ADDRESS", "THANK YOU"
    ]
    private static let headings: Set<String> = [
        "STARTERS", "MAINS", "DRINKS", "SIDES", "DESSERTS", "ITEMS", "PRODUCTS",
        "BEVERAGES", "GROCERIES", "ENTREES", "SNACKS", "APPETIZERS", "MERCHANDISE"
    ]

    static func classify(_ text: String) -> Self {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if raw.range(of: #"^[A-Z]{2,12}\s*#"#, options: .regularExpression) != nil {
            return .paymentMetadata
        }
        let words = raw.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        func matches(_ fields: [String]) -> Bool {
            fields.contains { words == $0 || words.hasPrefix($0 + " ") }
        }
        if headings.contains(words) { return .heading }
        if matches(otherFields) { return .other }
        if matches(summaries) { return .financialSummary }
        if matches(payments) { return .paymentMetadata }
        guard raw.rangeOfCharacter(from: .letters) != nil,
              !raw.hasPrefix("HTTP"), !raw.contains("@") else { return .other }
        return .product // Product candidate proposed by AI; numeric verification is separate.
    }
}

/// Verifies individual product-price associations without requiring the *entire*
/// receipt to reconcile. A separately misread price must not erase good line items.
enum ReceiptProductEvidenceVerifier {
    struct Verified: Sendable {
        let line: Int
        let product: ReceiptCostBreakdown.Product
    }

    private static let amountPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])((?:(?:A\$|AUD|USD|NZD|EUR|GBP|[$£€¥])\s*)?[-+]?[0-9]{1,9}[.,][0-9]{2})(?![A-Za-z0-9])"#,
        options: [.caseInsensitive]
    )

    private static func clean(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private static func plausibleName(_ text: String) -> Bool {
        ReceiptOCRRowKind.classify(text) == .product && !isPriceOnly(text)
    }

    private static func isPriceOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return amountPattern.firstMatch(in: trimmed, range: range)?.range == range
    }

    static func printedQuantity(in text: String) -> Decimal? {
        let regex = try! NSRegularExpression(pattern: #"(?i)(?:[x×]\s*([0-9]+(?:[.,][0-9]+)?)\b|\b([0-9]+(?:[.,][0-9]+)?)\s*[x×])"#)
        let values = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Decimal? in
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            return Range(range, in: text).flatMap { ReceiptAmountParser.printed(String(text[$0])) }
        }
        return Set(values).count == 1 ? values.first : nil
    }

    /// A quantity-marked row with one monetary token has one printed amount,
    /// even if the model incorrectly multiplied it. This never calculates a price.
    static func singlePrintedQuantityAmount(in context: String) -> Decimal? {
        guard printedQuantity(in: context) != nil else { return nil }
        let prices = amountTokens(in: context)
        return prices.count == 1 ? prices.first?.price : nil
    }

    /// Physical OCR coverage, not product count or receipt arithmetic, drives recovery.
    static func retryLines(chunk: ReceiptOCRChunk, mapped: ReceiptExtractionMapper.Mapped) -> Set<Int> {
        var covered = Set<Int>()
        var targets = Set<Int>()
        for item in mapped.anchoredProducts {
            if item.product.lineTotal == nil { targets.insert(item.line); continue }
            if let anchor = ReceiptExtractionMapper.productAnchor(name: item.product.name, sourceLine: item.line, chunk: chunk) {
                let first = chunk.startLine + anchor.offset
                covered.formUnion(first..<(first + anchor.context.components(separatedBy: .newlines).count))
            }
        }
        for index in chunk.lines.indices {
            let line = chunk.lines[index]
            guard !covered.contains(chunk.startLine + index), !amountTokens(in: line).isEmpty else { continue }
            let kind = ReceiptOCRRowKind.classify(line)
            guard kind == .product || line.rangeOfCharacter(from: .letters) == nil ||
                    line.trimmingCharacters(in: .whitespaces).range(of: #"^(?:AUD|USD|NZD|EUR|GBP)\s*[-+0-9]"#, options: .regularExpression) != nil else { continue }
            if kind == .product && !isPriceOnly(line) { targets.insert(chunk.startLine + index) }
            // Include unpriced wrapped descriptions, stopping at another priced
            // product, a classified non-product row, or already verified coverage.
            for previous in stride(from: index - 1, through: max(0, index - 2), by: -1) {
                guard !covered.contains(chunk.startLine + previous),
                      plausibleName(chunk.lines[previous]), amountTokens(in: chunk.lines[previous]).isEmpty else { break }
                targets.insert(chunk.startLine + previous)
            }
        }
        return targets
    }

    static func retryContext(chunk: ReceiptOCRChunk, targets: Set<Int>) -> (text: String, lines: Set<Int>) {
        var selected = targets
        for line in targets {
            let offset = line - chunk.startLine
            for next in (offset + 1)..<min(chunk.lines.count, offset + 4) {
                let text = chunk.lines[next]
                guard targets.contains(chunk.startLine + next) ||
                      text.rangeOfCharacter(from: .letters) == nil ||
                      text.range(of: #"^(?:AUD|USD|NZD|EUR|GBP)\s*[-+0-9]"#, options: .regularExpression) != nil else { break }
                selected.insert(chunk.startLine + next)
            }
        }
        let rows = chunk.lines.enumerated().compactMap { index, text in
            selected.contains(chunk.startLine + index) ? "\(chunk.startLine + index): \(text)" : nil
        }
        return ("Investigate only these unmatched or unresolved product rows. Keep global line numbers; omitted lines are NOT adjacent.\n" + rows.joined(separator: "\n"), selected)
    }

    private struct PriceToken {
        let start: String.Index
        let price: Decimal
    }

    private static func amountTokens(in text: String) -> [PriceToken] {
        let search = NSRange(text.startIndex..<text.endIndex, in: text)
        return amountPattern.matches(in: text, range: search).compactMap { match in
            guard let fullRange = Range(match.range(at: 1), in: text),
                  let value = ReceiptAmountParser.printed(String(text[fullRange])) else {
                return nil
            }
            return PriceToken(start: fullRange.lowerBound, price: value)
        }
    }

    /// Match against the anchored OCR line; allow the next line only for a
    /// wrapped name or a price-only line. Never take a price from the next product.
    static func verify(
        _ proposals: [FocusedReceiptProductProposal],
        lines: [String],
        startLine: Int,
        allowedLines: Set<Int>? = nil,
        diagnose: (String) -> Void = { _ in }
    ) -> [Verified] {
        var accepted: [Verified] = []
        var claimedLines = Set<Int>()

        for proposal in proposals {
            guard let resolved = ReceiptExtractionMapper.productAnchor(name: proposal.name,
                sourceLine: proposal.sourceLine, chunk: .init(startLine: startLine, lines: lines)) else {
                diagnose("Rejected \(proposal.name): identity is not a unique product anchor.")
                continue
            }
            let index = resolved.offset
            let resolvedLine = startLine + index
            guard allowedLines?.contains(resolvedLine) != false else {
                diagnose("Rejected \(proposal.name): row already verified or outside retry targets.")
                continue
            }
            guard lines.indices.contains(index),
                  !claimedLines.contains(resolvedLine),
                  plausibleName(proposal.name),
                  plausibleName(lines[index]),
                  let printed = proposal.lineTotal,
                  let proposedAmount = ReceiptAmountParser.printed(printed) else {
                diagnose("Rejected \(proposal.name): duplicate, non-product, or missing printed price.")
                continue
            }

            // Reuse the mapper's verified identity/continuation span. The old
            // second two-line check discarded valid three-line and currency-code rows.
            let prices = amountTokens(in: resolved.context)
            guard let printedLineCost = prices.last?.price,
                  printedLineCost == proposedAmount else {
                diagnose("Rejected \(proposal.name): proposed price is not the printed line cost.")
                continue
            }

            var quantity: Decimal? = printedQuantity(in: resolved.context)
            if let token = proposal.quantity,
               let value = ReceiptAmountParser.printed(token), value > 0 {
                // Quantity needs its own evidence, e.g. "x2", "2 x", or "0.5kg".
                // Never derive it from the line price.
                let escaped = NSRegularExpression.escapedPattern(for: token)
                let pattern = #"(?i)(?:[x×]\s*"# + escaped + #"\b|\b"# + escaped + #"\s*[x×]|\b"# + escaped + #"\s*(?:kg|g|l|ml)\b)"#
                if resolved.context.range(of: pattern, options: .regularExpression) != nil {
                    quantity = value
                }
            }

            accepted.append(Verified(
                line: resolvedLine,
                product: ReceiptCostBreakdown.Product(
                    name: proposal.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: quantity,
                    unitPrice: nil,
                    lineTotal: proposedAmount,
                    discount: nil,
                    isReturn: false
                )
            ))
            claimedLines.formUnion(resolvedLine..<(resolvedLine + resolved.context.components(separatedBy: .newlines).count))
            diagnose("Accepted \(proposal.name) at OCR line \(resolvedLine): \(proposedAmount).")
        }
        return accepted
    }

    /// Add only genuinely missing products/amounts. Never override existing
    /// verified fields or modify subtotal, tax, fees, discounts or final total.
    static func merge(
        _ verified: [Verified],
        into original: ReceiptExtractionMapper.Mapped
    ) -> ReceiptExtractionMapper.Mapped {
        var result = original
        var anchored = original.anchoredProducts

        for candidate in verified {
            let candidateName = clean(candidate.product.name)
            if let index = anchored.firstIndex(where: {
                $0.line == candidate.line && clean($0.product.name) == candidateName
            }) {
                if anchored[index].product.lineTotal == nil {
                    anchored[index].product.lineTotal = candidate.product.lineTotal
                }
                if anchored[index].product.quantity == nil {
                    anchored[index].product.quantity = candidate.product.quantity
                }
            } else if !anchored.contains(where: {
                $0.line == candidate.line
            }) {
                anchored.append((line: candidate.line, product: candidate.product))
            }
        }

        // A chunk may overlap another chunk. combine() deduplicates by line.
        result.anchoredProducts = anchored.sorted(by: { $0.line < $1.line })
        result.costs.products = result.anchoredProducts.map(\.product)
        return result
    }
}
