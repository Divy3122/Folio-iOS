import Foundation

/// Conservative recovery for a complete, legible OCR receipt table.
/// Inspired by deterministic receipt parsers: OCR rows remain the evidence;
/// the model is not trusted to manufacture amounts or table structure.
/// This only fills an EMPTY product breakdown when accounting reconciles.
enum VerifiedReceiptOCRRecovery {
    private struct Candidate {
        var products: [ReceiptCostBreakdown.Product] = []
        var subTotals: [Decimal] = []
        var taxAmounts: [Decimal] = []
        var totals: [Decimal] = []
        var taxTreatment: ReceiptCostBreakdown.TaxTreatment = .unknown
    }

    private static let amountAtEnd = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])((?:(?:A\$|GBP|EUR|AUD|USD|NZD|[$£€¥])\s*)?[-+]?[0-9]{1,9}[.,][0-9]{2})\s*$"#,
        options: [.caseInsensitive]
    )
    private static let multiplier = try! NSRegularExpression(
        pattern: #"\s+[x×]\s*([0-9]+(?:[.,][0-9]+)?)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let headings: Set<String> = [
        "STARTERS", "MAINS", "DRINKS", "SIDES", "DESSERTS", "ENTREES",
        "APPETIZERS", "ITEMS", "PRODUCTS", "GROCERIES", "BEVERAGES",
        "SNACKS", "MERCHANDISE"
    ]
    private static let disallowedPrefixes = [
        "TOTAL", "SUBTOTAL", "SUB TOTAL", "VAT", "GST", "TAX", "CASH",
        "CHANGE", "PAYMENT", "PAID", "TENDER", "EFTPOS", "VISA",
        "MASTERCARD", "DEBIT", "CREDIT", "LOYALTY", "REWARD", "POINTS",
        "SAVING", "DISCOUNT", "ROUNDING", "BALANCE", "AMOUNT DUE",
        "FEE", "SURCHARGE", "AUTH", "TRANSACTION", "RECEIPT", "INVOICE",
        "DATE", "TIME", "TABLE", "SERVER", "TEL", "PHONE", "ADDRESS",
        "ABN", "VAT NO", "VAT REG", "PAGE", "THANK YOU", "ORDER NO"
    ]

    private static func amountPair(_ raw: String) -> (label: String, amount: Decimal)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = amountAtEnd.firstMatch(in: line, range: range),
              let tokenRange = Range(match.range(at: 1), in: line),
              let entireRange = Range(match.range, in: line),
              let amount = ReceiptAmountParser.printed(String(line[tokenRange])) else {
            return nil
        }
        return (String(line[..<entireRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), amount)
    }

    private static func safeProductName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = name.uppercased()
        guard name.rangeOfCharacter(from: .letters) != nil,
              !headings.contains(upper), !upper.hasPrefix("PAGE "),
              !upper.hasPrefix("HTTP"), !upper.contains("@") else { return false }
        return !disallowedPrefixes.contains { word in
            upper == word || upper.hasPrefix(word + " ") ||
            upper.hasPrefix(word + ":") || upper.hasPrefix(word + "(")
        }
    }

    private static func product(_ raw: String, amount: Decimal) -> ReceiptCostBreakdown.Product? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeProductName(name) else { return nil }
        var quantity: Decimal?
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        if let match = multiplier.firstMatch(in: name, range: range),
           let tokenRange = Range(match.range(at: 1), in: name),
           let matchRange = Range(match.range, in: name) {
            let token = String(name[tokenRange]).replacingOccurrences(of: ",", with: ".")
            quantity = ReceiptAmountParser.parse(token)
            name.removeSubrange(matchRange)
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard safeProductName(name), amount >= 0 else { return nil }
        return .init(name: name, quantity: quantity, unitPrice: nil,
                     lineTotal: amount, discount: nil, isReturn: false)
    }

    private static func onlyOne(_ values: [Decimal]) -> Decimal? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func approximately(_ a: Decimal, _ b: Decimal) -> Bool {
        abs(a - b) <= Decimal(string: "0.01")!
    }

    private static func parse(_ rawText: String) -> ReceiptCostBreakdown? {
        let lines = rawText.components(separatedBy: .newlines)
        var candidate = Candidate()
        var pendingNames: [String] = []
        var pendingPrices: [Decimal] = []
        var inItems = false
        var finishedItems = false

        func flush() {
            if !pendingNames.isEmpty && pendingNames.count == pendingPrices.count {
                for (name, price) in zip(pendingNames, pendingPrices) {
                    if let item = product(name, amount: price) { candidate.products.append(item) }
                }
            }
            pendingNames.removeAll()
            pendingPrices.removeAll()
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("PAGE ") || line.allSatisfy({ $0 == "-" || $0 == "_" }) {
                flush()
                continue
            }
            if upper.hasPrefix("SUBTOTAL") || upper.hasPrefix("SUB TOTAL") {
                flush(); finishedItems = true
                if let value = amountPair(line)?.amount { candidate.subTotals.append(value) }
                if upper.contains("EXCL") || upper.contains("BEFORE TAX") { candidate.taxTreatment = .added }
                if upper.contains("INCL") || upper.contains("INCLUDING TAX") { candidate.taxTreatment = .included }
                continue
            }
            if upper.hasPrefix("VAT NO") || upper.hasPrefix("VAT REG") { continue }
            if upper.hasPrefix("VAT (") || upper.hasPrefix("VAT:") || upper.hasPrefix("GST") ||
                upper.hasPrefix("TAX (") || upper.hasPrefix("TAX:") {
                flush(); finishedItems = true
                if let value = amountPair(line)?.amount { candidate.taxAmounts.append(value) }
                continue
            }
            if upper == "TOTAL" || upper.hasPrefix("TOTAL ") || upper.hasPrefix("TOTAL:") ||
                upper.hasPrefix("GRAND TOTAL") || upper.hasPrefix("AMOUNT DUE") ||
                upper.hasPrefix("AMOUNT PAID") {
                flush(); finishedItems = true
                if let value = amountPair(line)?.amount { candidate.totals.append(value) }
                continue
            }
            if headings.contains(upper) { flush(); inItems = true; continue }
            if finishedItems { continue }

            if let pair = amountPair(line) {
                if pair.label.isEmpty {
                    // Vision may put several product descriptions in one column,
                    // followed by their prices in a second column.
                    if !pendingNames.isEmpty { pendingPrices.append(pair.amount) }
                } else if safeProductName(pair.label) {
                    inItems = true
                    // Wrapped product description: "Pan-Seared Salmon w/" then
                    // "New Potatoes £17,90".
                    if pendingPrices.isEmpty && pendingNames.count == 1 &&
                        (pendingNames[0].hasSuffix("w/") || pendingNames[0].hasSuffix("with")) {
                        let name = pendingNames.removeLast() + " " + pair.label
                        if let item = product(name, amount: pair.amount) { candidate.products.append(item) }
                    } else {
                        flush()
                        if let item = product(pair.label, amount: pair.amount) { candidate.products.append(item) }
                    }
                }
            } else if inItems && safeProductName(line) {
                if !pendingPrices.isEmpty { flush() }
                pendingNames.append(line)
            }
        }
        flush()

        guard candidate.products.count >= 2,
              let total = onlyOne(candidate.totals),
              !candidate.totals.isEmpty, // Never guess an unprinted final total.
              candidate.subTotals.isEmpty || onlyOne(candidate.subTotals) != nil,
              candidate.taxAmounts.isEmpty || onlyOne(candidate.taxAmounts) != nil else { return nil }

        let sum = candidate.products.reduce(Decimal.zero) { $0 + ($1.lineTotal ?? 0) }
        let subtotal = onlyOne(candidate.subTotals)
        let tax = onlyOne(candidate.taxAmounts)
        // If adjustments are missing, decline recovery instead of guessing them.
        if let subtotal {
            guard approximately(sum, subtotal) else { return nil }
            if candidate.taxTreatment == .added {
                guard let tax, approximately(subtotal + tax, total) else { return nil }
            } else {
                guard approximately(subtotal, total) else { return nil }
            }
        } else {
            guard tax == nil, approximately(sum, total) else { return nil }
        }
        return ReceiptCostBreakdown(products: candidate.products, subtotal: subtotal,
            discounts: nil, tax: tax, fees: nil, rounding: nil, total: total,
            taxTreatment: candidate.taxTreatment, discountTreatment: .unknown)
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Uses a full, reconciled OCR table to repair *missing* product fields.
    /// Existing verified values remain unchanged; incompatible OCR is ignored.
    /// Manual edits are never touched: the ViewModel calls this before displaying
    /// extraction results and its edit-revision guard prevents late overwrites.
    static func recoverIfComplete(
        _ result: ReceiptExtractionResult,
        from rawText: String
    ) -> ReceiptExtractionResult {
        let prior = result.costBreakdown ?? ReceiptCostBreakdown()
        let hasJunk = prior.products.contains { !safeProductName($0.name) }
        let incomplete = prior.products.isEmpty || hasJunk ||
            prior.products.contains { $0.lineTotal == nil } ||
            prior.total == nil || prior.subtotal == nil ||
            (prior.tax != nil && prior.taxTreatment == .unknown)

        // We do not attempt a recovery that could omit discounts, fees or rounding.
        guard incomplete,
              (prior.fees ?? 0) == 0,
              (prior.discounts ?? 0) == 0,
              (prior.rounding ?? 0) == 0,
              let recovered = parse(rawText) else { return result }

        // Verify every previously accepted product against one distinct OCR row.
        // This preserves real repeated purchases instead of matching both to one row.
        var matchedIndices = Set<Int>()
        var associations: [Int: Int] = [:]  // recovered index -> prior index
        for (priorIndex, existing) in prior.products.enumerated() where safeProductName(existing.name) {
            guard let recoveredIndex = recovered.products.indices.first(where: { index in
                !matchedIndices.contains(index) &&
                key(existing.name) == key(recovered.products[index].name) &&
                (existing.lineTotal == nil || existing.lineTotal == recovered.products[index].lineTotal) &&
                (existing.quantity == nil || existing.quantity == recovered.products[index].quantity ||
                    recovered.products[index].quantity == nil)
            }) else { return result }
            matchedIndices.insert(recoveredIndex)
            associations[recoveredIndex] = priorIndex
        }

        func compatible(_ old: Decimal?, _ verified: Decimal?) -> Bool {
            guard let old, let verified else { return true }
            return approximately(old, verified)
        }
        guard compatible(prior.subtotal, recovered.subtotal),
              compatible(prior.tax, recovered.tax),
              compatible(prior.total, recovered.total) else { return result }

        var updated = result
        var merged = prior
        merged.products = recovered.products.enumerated().map { index, ocrProduct in
            guard let existingIndex = associations[index] else { return ocrProduct }
            var original = prior.products[existingIndex]
            original.quantity = original.quantity ?? ocrProduct.quantity
            original.lineTotal = original.lineTotal ?? ocrProduct.lineTotal
            // Do not infer unit prices or missing discounts from printed line totals.
            return original
        }
        merged.subtotal = merged.subtotal ?? recovered.subtotal
        merged.tax = merged.tax ?? recovered.tax
        merged.total = merged.total ?? recovered.total

        // Explicit 'subtotal excluding VAT' plus 'subtotal + VAT = total'
        // outranks the language model's guessed tax-treatment label.
        if recovered.taxTreatment == .added,
           let subtotal = recovered.subtotal, let tax = recovered.tax,
           let total = recovered.total,
           approximately(subtotal + tax, total),
           !approximately(subtotal, total) {
            merged.taxTreatment = .added
        } else if merged.taxTreatment == .unknown {
            merged.taxTreatment = recovered.taxTreatment
        }

        updated.costBreakdown = merged
        // Keep raw model diagnostics unchanged for the collapsed diagnostic view.
        // They are not user-facing validation failures by themselves.
        return updated
    }
}
