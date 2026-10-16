import Foundation

struct ReceiptOCRChunk: Sendable {
    let startLine: Int
    let lines: [String]
    var text: String { lines.joined(separator: "\n") }
    var numberedText: String {
        lines.enumerated().map { "\(startLine + $0.offset): \($0.element)" }.joined(separator: "\n")
    }

    /// Bounded context with overlap for wrapped names/amounts across pages and chunks.
    static func split(_ text: String, limit: Int = 2400) -> [Self] {
        let lines = text.components(separatedBy: .newlines)
        var chunks: [Self] = []
        var start = 0
        while start < lines.count {
            var end = start
            var count = 0
            while end < lines.count && end - start < 16 && (count + lines[end].count <= limit || end == start) {
                count += lines[end].count + 1
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

    static func map(_ generated: GeneratedReceiptCosts, chunk: ReceiptOCRChunk) -> Mapped {
        var warnings: [String] = []
        func supported(_ quote: String) -> Bool {
            !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalized(chunk.text).contains(normalized(quote))
        }
        func amount(_ token: String?, evidence: String, label: String) -> Decimal? {
            guard let token else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: token)
            guard supported(evidence), !token.isEmpty,
                  evidence.range(of: "(?<![0-9.,])" + escaped + "(?![0-9.,])", options: .regularExpression) != nil,
                  let value = ReceiptAmountParser.printed(token) else {
                warnings.append("\(label) could not be verified against the OCR and was left missing.")
                return nil
            }
            return value
        }
        func summary(_ value: GeneratedReceiptAmount?, _ label: String) -> Decimal? {
            value.flatMap { amount($0.printed, evidence: $0.evidence, label: label) }
        }
        var products: [(line: Int, product: ReceiptCostBreakdown.Product)] = []
        for item in generated.products {
            let name = normalized(item.name)
            // Guard against obvious metadata even if the model misclassifies it.
            let metadata = #"(?i)^(cash|change|visa|mastercard|eftpos|credit card|debit card|payment|subtotal|sub total|total|gst|tax|balance|loyalty|points|rounding|discount|savings)(\s+[0-9$.,%+-]+)?$"#
            let offset = item.sourceLine - chunk.startLine
            guard offset >= 0, offset < chunk.lines.count,
                  supported(item.evidence), !name.isEmpty,
                  normalized(item.evidence).contains(name),
                  normalized(item.evidence).hasPrefix(normalized(chunk.lines[offset])),
                  name.range(of: metadata, options: .regularExpression) == nil else {
                warnings.append("An unsupported product or metadata row was omitted. Check the original receipt for missing products.")
                continue
            }
            let product = ReceiptCostBreakdown.Product(name: name,
                quantity: amount(item.quantity, evidence: item.evidence, label: "\(name) quantity"),
                unitPrice: amount(item.unitPrice, evidence: item.evidence, label: "\(name) unit price"),
                lineTotal: amount(item.lineTotal, evidence: item.evidence, label: "\(name) line cost"),
                discount: amount(item.discount, evidence: item.evidence, label: "\(name) discount").map { abs($0) },
                isReturn: item.isReturn)
            products.append((item.sourceLine, product))
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
