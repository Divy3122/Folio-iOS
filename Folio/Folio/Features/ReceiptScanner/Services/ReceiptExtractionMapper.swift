import Foundation

struct ReceiptOCRChunk: Sendable {
    let startLine: Int
    let lines: [String]
    var text: String { lines.joined(separator: "\n") }
    var numberedText: String {
        lines.enumerated().map { "\(startLine + $0.offset): \($0.element)" }.joined(separator: "\n")
    }

    /// Bounded context with overlap for wrapped names/amounts across pages and chunks.
    // Reserve output and prompt/schema space in the 4,096-token model context.
    // UTF-8 bytes conservatively bound input tokens; no tokenizer is exposed by this SDK.
    static let inputBudget = 4096 - 1800 - 1000

    static func split(_ text: String, limit: Int = inputBudget) -> [Self] {
        let lines = text.components(separatedBy: .newlines)
        var chunks: [Self] = []
        var start = 0
        while start < lines.count {
            var end = start
            var count = 0
            while end < lines.count && (count + lines[end].utf8.count + String(end + 1).count + 3 <= limit || end == start) {
                count += lines[end].utf8.count + String(end + 1).count + 3
                end += 1
            }
            chunks.append(Self(startLine: start + 1, lines: Array(lines[start..<end])))
            if end == lines.count { break }
            start = max(start + 1, end - 4)
        }
        return chunks
    }
}

enum ReceiptExtractionMapper {
    struct Mapped: Sendable {
        var costs: ReceiptCostBreakdown
        var anchoredProducts: [(line: Int, product: ReceiptCostBreakdown.Product)]
        var warnings: [String]
        var anchoredFees: [(line: Int, amount: Decimal)] = []
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func evidenceKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let numericToken = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.,])(?:\([+-]?[0-9]+(?:[.,][0-9]+)*\)|[+-]?[0-9]+(?:[.,][0-9]+)*-?)(?![\p{L}\p{N}.,])"#
    )

    private static func containsAmount(_ value: Decimal, in text: String) -> Bool {
        numericToken.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains {
            guard let range = Range($0.range, in: text) else { return false }
            return ReceiptAmountParser.printed(String(text[range])) == value
        }
    }

    /// Only numeric/currency/quantity continuations; never borrow from another named row.
    private static func isNumericContinuation(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(
            of: #"(?i)\b(?:AUD|USD|NZD|EUR|GBP|kg|g|ml|l|x)\b"#,
            with: "", options: .regularExpression)
        return stripped.rangeOfCharacter(from: .letters) == nil
    }

    private static func productContext(name: String, offset: Int, lines: [String]) -> String? {
        guard lines.indices.contains(offset), !name.isEmpty else { return nil }
        let target = evidenceKey(name)
        var context = lines[offset]
        for index in (offset + 1)..<min(lines.count, offset + 4) {
            let next = lines[index]
            if evidenceKey(context).contains(target) {
                guard isNumericContinuation(next) || next.range(of: #"^Page [0-9]+$"#, options: .regularExpression) != nil else { break }
            } else if !target.hasPrefix(evidenceKey(context)) { break }
            context += "\n" + next
        }
        return evidenceKey(context).contains(target) ? context : nil
    }

    /// Line numbers are model proposals too. Relocate only a uniquely matching
    /// product identity; repeated names require a correct explicit anchor.
    static func productAnchor(name: String, sourceLine: Int, chunk: ReceiptOCRChunk) -> (offset: Int, context: String)? {
        guard ReceiptOCRRowKind.classify(name) == .product else { return nil }
        func match(_ offset: Int) -> String? {
            guard chunk.lines.indices.contains(offset),
                  ReceiptOCRRowKind.classify(chunk.lines[offset]) == .product else { return nil }
            return productContext(name: name, offset: offset, lines: chunk.lines)
        }
        let offset = sourceLine - chunk.startLine
        if let context = match(offset) { return (offset, context) }
        let matches = chunk.lines.indices.compactMap { index -> (Int, String)? in
            match(index).map { (index, $0) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func map(_ generated: GeneratedReceiptCosts, chunk: ReceiptOCRChunk) -> Mapped {
        var warnings: [String] = []
        func supported(_ quote: String) -> Bool {
            !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalized(chunk.text).contains(normalized(quote))
        }
        func amount(_ token: String?, evidence: String, label: String, printedFallback: Decimal? = nil) -> Decimal? {
            guard let token else { return printedFallback }
            guard let value = ReceiptAmountParser.printed(token), containsAmount(value, in: evidence) else {
                if let printedFallback {
                    warnings.append("\(label): the unsupported AI amount was discarded; the sole printed amount on the quantity row was retained.")
                    return printedFallback
                }
                warnings.append("\(label) could not be verified against the OCR and was left missing.")
                return nil
            }
            return value
        }
        func summary(_ proposal: GeneratedReceiptAmount?, _ label: String) -> Decimal? {
            guard let proposal, !evidenceKey(proposal.evidence).isEmpty else { return nil }
            // An unsigned adjustment blank is not evidence of a printed amount.
            if proposal.evidence.contains("_"),
               numericToken.firstMatch(in: proposal.evidence,
                   range: NSRange(proposal.evidence.startIndex..., in: proposal.evidence)) == nil { return nil }
            // Match the label/quote despite OCR whitespace, punctuation or decimal separator.
            // Continuation amounts must be on numeric rows, not a neighbouring product.
            for index in chunk.lines.indices {
                var context = chunk.lines[index]
                for next in (index + 1)..<min(chunk.lines.count, index + 3) {
                    guard isNumericContinuation(chunk.lines[next]) else { break }
                    context += "\n" + chunk.lines[next]
                }
                if evidenceKey(context).contains(evidenceKey(proposal.evidence)),
                   let value = ReceiptAmountParser.printed(proposal.printed), containsAmount(value, in: context) {
                    return value
                }
            }
            warnings.append("\(label) could not be verified against the OCR and was left missing.")
            return nil
        }
        var products: [(line: Int, product: ReceiptCostBreakdown.Product)] = []
        for item in generated.products {
            let name = normalized(item.name)
            guard ReceiptOCRRowKind.classify(name) == .product else { continue }
            guard let anchor = productAnchor(name: name, sourceLine: item.sourceLine, chunk: chunk) else {
                warnings.append("Product identity could not be anchored: \(name) (proposed line \(item.sourceLine)).")
                continue
            }
            let context = anchor.context
            let singleQuantityAmount = ReceiptProductEvidenceVerifier.singlePrintedQuantityAmount(in: context)
            let product = ReceiptCostBreakdown.Product(name: name,
                quantity: ReceiptProductEvidenceVerifier.printedQuantity(in: context) ?? amount(item.quantity, evidence: context, label: "\(name) quantity"),
                unitPrice: singleQuantityAmount == nil ? amount(item.unitPrice, evidence: context, label: "\(name) unit price") : nil,
                lineTotal: amount(item.lineTotal, evidence: context, label: "\(name) line cost", printedFallback: singleQuantityAmount),
                discount: amount(item.discount, evidence: context, label: "\(name) discount").map { abs($0) },
                isReturn: item.isReturn)
            products.append((chunk.startLine + anchor.offset, product))
        }
        let taxTreatment: ReceiptCostBreakdown.TaxTreatment
        switch generated.taxTreatment {
        case .included: taxTreatment = .included
        case .added: taxTreatment = .added
        case .unknown: taxTreatment = .unknown
        }
        let discountTreatment: ReceiptCostBreakdown.DiscountTreatment
        switch generated.discountTreatment {
        case .includedInLines: discountTreatment = .includedInLines
        case .deductedFromLines: discountTreatment = .deductedFromLines
        case .unknown: discountTreatment = .unknown
        }
        var fees: [(line: Int, amount: Decimal)] = []
        for fee in generated.fees {
            let offset = fee.sourceLine - chunk.startLine
            guard offset >= 0, offset < chunk.lines.count,
                  supported(fee.amount.evidence),
                  normalized(fee.amount.evidence).hasPrefix(normalized(chunk.lines[offset])),
                  let value = amount(fee.amount.printed, evidence: fee.amount.evidence, label: "Additional fee") else {
                warnings.append("An additional fee could not be verified. Check the fee total manually.")
                continue
            }
            if products.contains(where: { $0.line == fee.sourceLine }) {
                warnings.append("A fee also appeared as a product; it was kept only in product costs to avoid double counting.")
            } else { fees.append((fee.sourceLine, value)) }
        }
        let costs = ReceiptCostBreakdown(products: products.map(\.product),
            subtotal: summary(generated.subtotal, "Subtotal"), discounts: summary(generated.discounts, "Discounts").map { abs($0) },
            tax: summary(generated.tax, "GST / tax"), fees: fees.isEmpty ? nil : fees.reduce(0) { $0 + $1.amount },
            rounding: summary(generated.rounding, "Rounding"), total: summary(generated.total, "Final total"),
            taxTreatment: taxTreatment, discountTreatment: discountTreatment)
        return Mapped(costs: costs, anchoredProducts: products, warnings: warnings, anchoredFees: fees)
    }

    static func combine(_ parts: [Mapped], rawText: String, warnings initial: [String] = []) -> ReceiptExtractionResult {
        var costs = ReceiptCostBreakdown()
        var warnings = initial + parts.flatMap(\.warnings)
        var products: [Int: ReceiptCostBreakdown.Product] = [:]
        for part in parts {
            for (line, product) in part.anchoredProducts {
                if var existing = products[line] {
                    // Overlap refers to the same physical row, not a second purchase.
                    if existing.name != product.name || (existing.lineTotal != nil && product.lineTotal != nil && existing.lineTotal != product.lineTotal) {
                        warnings.append("Overlapping OCR produced conflicting product details. Review \(existing.name).")
                    }
                    existing.quantity = existing.quantity ?? product.quantity
                    existing.unitPrice = existing.unitPrice ?? product.unitPrice
                    existing.lineTotal = existing.lineTotal ?? product.lineTotal
                    existing.discount = existing.discount ?? product.discount
                    products[line] = existing
                } else { products[line] = product }
            }
        }
        costs.products = products.keys.sorted().compactMap { products[$0] }
        // Distinct printed totals are ambiguous; never choose one just because the maths fits.
        func merge(_ key: KeyPath<ReceiptCostBreakdown, Decimal?>, _ label: String) -> Decimal? {
            let values = parts.compactMap { $0.costs[keyPath: key] }
            guard let first = values.first else { return nil }
            guard values.allSatisfy({ $0 == first }) else {
                warnings.append("Conflicting \(label) values were found across pages. Enter the correct printed amount manually.")
                return nil
            }
            return first
        }
        costs.subtotal = merge(\.subtotal, "subtotal")
        costs.discounts = merge(\.discounts, "discount")
        costs.tax = merge(\.tax, "tax")
        var fees: [Int: Decimal] = [:]
        var conflictingFees = false
        for fee in parts.flatMap(\.anchoredFees) where products[fee.line] == nil {
            if let previous = fees[fee.line], previous != fee.amount { conflictingFees = true }
            fees[fee.line] = fee.amount
        }
        if conflictingFees {
            warnings.append("Conflicting fee amounts were found. Enter the combined fees manually.")
        } else if !fees.isEmpty { costs.fees = fees.values.reduce(0, +) }
        costs.rounding = merge(\.rounding, "rounding")
        costs.total = merge(\.total, "final total")
        let taxes = Set(parts.map { $0.costs.taxTreatment }.filter { $0 != .unknown })
        costs.taxTreatment = taxes.count == 1 ? taxes.first! : .unknown
        let discounts = Set(parts.map { $0.costs.discountTreatment }.filter { $0 != .unknown })
        costs.discountTreatment = discounts.count == 1 ? discounts.first! : .unknown
        return ReceiptExtractionResult(rawText: rawText, candidate: nil,
            source: parts.isEmpty ? .vision : .foundationModels,
            reviewWarnings: Array(Set(warnings)).sorted(), costBreakdown: costs)
    }
}
