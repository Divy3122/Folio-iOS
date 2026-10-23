import Foundation

/// A conservative, deterministic audit of receipt OCR. It never invents missing
/// values and never treats model output as proof that a printed amount is correct.
enum ReceiptScanQualityAudit {
    struct Result {
        var warnings: [String] = []
        var ambiguousSubtotal = false
        var ambiguousTotal = false
    }

    static func inspect(text: String, pages: [ReceiptOCRPage], expectedPageCount: Int) -> Result {
        var result = Result()
        if pages.count < expectedPageCount && !pages.isEmpty {
            result.warnings.append("Some pages have no OCR evidence. Check their original images.")
        }

        // Read each candidate row independently to spot disagreements that the
        // simple totals reader otherwise resolves by precedence/order.
        var subtotals: Set<Decimal> = []
        var totals: Set<Decimal> = []
        let lines = text.components(separatedBy: .newlines)
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.range(of: #"(?i)^sub[\s-]*total\b"#, options: .regularExpression) != nil {
                let sample = line + (i + 1 < lines.count ? "\n" + lines[i + 1] : "")
                if let amount = ReceiptSimpleTotals.read(ocrText: line).subtotal ?? ReceiptSimpleTotals.read(ocrText: sample).subtotal { subtotals.insert(amount) }
            }
            if line.range(of: #"(?i)^(?:(?:grand|final)\s+total|total(?:\s+(?:amount\s+paid|paid|due))?|amount\s+(?:paid|due)|balance\s+due)\b"#, options: .regularExpression) != nil {
                let sample = line + (i + 1 < lines.count ? "\n" + lines[i + 1] : "")
                if let amount = ReceiptSimpleTotals.read(ocrText: line).total ?? ReceiptSimpleTotals.read(ocrText: sample).total { totals.insert(amount) }
            }
        }
        result.ambiguousSubtotal = subtotals.count > 1
        result.ambiguousTotal = totals.count > 1
        if result.ambiguousSubtotal {
            result.warnings.append("Conflicting printed subtotals detected. Verify the subtotal against the receipt.")
        }
        if result.ambiguousTotal {
            result.warnings.append("Conflicting printed totals detected. Verify the final amount against the receipt.")
        }

        // Vision's confidence is not calibrated as a probability. Use it only
        // to request review, and only when a suspect fragment contains a number.
        let suspect = pages.flatMap(\.lines).flatMap(\.fragments).filter {
            $0.confidence < 0.55 && $0.text.rangeOfCharacter(from: .decimalDigits) != nil
        }
        if !suspect.isEmpty {
            result.warnings.append("\(suspect.count) low-confidence number(s) detected. Compare item prices and totals with the scanned images.")
        }
        return result
    }

    static func protect(_ draft: inout ReceiptReviewDraft, audit: Result) {
        if audit.ambiguousSubtotal { draft.subtotal = "" }
        if audit.ambiguousTotal { draft.total = "" }
    }
}
