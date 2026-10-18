import Foundation

/// Strict, bounded decimal parsing; Decimal(string:) alone accepts partially invalid input.
enum ReceiptAmountParser {
    static func parse(_ input: String) -> Decimal? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[+-]?[0-9]{1,18}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    /// Only an actual printed numeric token is accepted. No OCR character substitution or guessing.
    static func printed(_ input: String) -> Decimal? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for symbol in ["AUD", "USD", "NZD", "EUR", "GBP", "$", "€", "£", "¥"] {
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.hasSuffix(")") { text = "-" + text.dropFirst().dropLast() }
        if text.hasSuffix("-") { text = "-" + text.dropLast() }
        if text.contains(",") {
            if text.contains(".") {
                // Unambiguous English grouping. Other formats stay missing for manual review.
                guard text.range(of: #"^[+-]?[0-9]{1,3}(,[0-9]{3})+\.[0-9]{1,6}$"#, options: .regularExpression) != nil else { return nil }
                text = text.replacingOccurrences(of: ",", with: "")
            } else if text.range(of: #"^[+-]?[0-9]+,[0-9]{1,2}$"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: ",", with: ".")
            } else { return nil } // 1,234 is ambiguous: never infer a price.
        }
        return parse(text)
    }

    static func text(_ value: Decimal?) -> String {
        value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }
}
