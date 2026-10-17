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
        ReceiptOCRRowKind.classify(text) == .product
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

    /// True only for a likely *item row* that carries a price, not a receipt total.
    /// Used to decide whether one narrow AI retry is worthwhile.
    static func hasUnmappedPricedRow(
        lines: [String],
        startLine: Int,
        mappedLines: Set<Int>
    ) -> Bool {
        for (index, line) in lines.enumerated() {
            guard !mappedLines.contains(startLine + index),
                  let firstPrice = amountTokens(in: line).first else { continue }
            let name = String(line.prefix(upTo: firstPrice.start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if plausibleName(name) { return true }
        }
        return false
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
        startLine: Int
    ) -> [Verified] {
        var accepted: [Verified] = []
        var claimedLines = Set<Int>()

        for proposal in proposals {
            guard let resolved = ReceiptExtractionMapper.productAnchor(name: proposal.name,
                sourceLine: proposal.sourceLine, chunk: .init(startLine: startLine, lines: lines)) else { continue }
            let index = resolved.offset
            let resolvedLine = startLine + index
            guard lines.indices.contains(index),
                  !claimedLines.contains(resolvedLine),
                  plausibleName(proposal.name),
                  plausibleName(lines[index]),
                  let printed = proposal.lineTotal,
                  let proposedAmount = ReceiptAmountParser.printed(printed) else { continue }

            let anchor = lines[index]
            let following = index + 1 < lines.count ? lines[index + 1] : ""
            let target = clean(proposal.name)
            let anchorName = clean(anchor)
            let combinedName = clean(anchor + " " + following)
            guard !target.isEmpty,
                  (anchorName.contains(target) || combinedName.contains(target)) else { continue }

            // A price belonging to a different product on the next line must
            // never be assigned to this one. Only a price-only continuation is safe.
            let mainPrices = amountTokens(in: anchor)
            let nextTrimmed = following.trimmingCharacters(in: .whitespacesAndNewlines)
            let continuation = mainPrices.isEmpty && (
                nextTrimmed.rangeOfCharacter(from: .letters) == nil ||
                (!anchorName.contains(target) && combinedName.contains(target))
            )
            let prices = continuation
                ? amountTokens(in: following)
                : mainPrices

            // On multi-price rows, the final printed amount is the line cost.
            // Don't mistake a unit price for the final extended line cost.
            guard let printedLineCost = prices.last?.price,
                  printedLineCost == proposedAmount else { continue }

            var quantity: Decimal? = printedQuantity(in: resolved.context)
            if let token = proposal.quantity,
               let value = ReceiptAmountParser.printed(token), value > 0 {
                // Quantity needs its own evidence, e.g. "x2", "2 x", or "0.5kg".
                // Never derive it from the line price.
                let escaped = NSRegularExpression.escapedPattern(for: token)
                let pattern = #"(?i)(?:[x×]\s*"# + escaped + #"\b|\b"# + escaped + #"\s*[x×]|\b"# + escaped + #"\s*(?:kg|g|l|ml)\b)"#
                if (anchor + " " + following).range(of: pattern, options: .regularExpression) != nil {
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
            claimedLines.insert(resolvedLine)
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
                $0.line == candidate.line ||
                (clean($0.product.name) == candidateName && abs($0.line - candidate.line) <= 1)
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
