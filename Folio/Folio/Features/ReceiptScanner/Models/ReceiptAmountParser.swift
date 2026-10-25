import Foundation

/// Strict, bounded decimal parsing; Decimal(string:) alone accepts partially invalid input.
enum ReceiptAmountParser {
    /// One monetary-token grammar for main mapping, retries and OCR recovery.
    /// Bare integers remain identifiers; currency-prefixed integers are money.
    private static let currency = #"(?:A\$|AUD|USD|NZD|EUR|GBP|CAD|CHF|JPY|[$£€¥])"#
    private static let decimal = #"(?:[0-9]{1,3}(?:[.,][0-9]{3})+[.,][0-9]{2}|[0-9]+[.,][0-9]{2})"#
    static let moneyTokenPattern = #"(?<![\p{L}\p{N}.,])((?:\((?:"# + currency + #"\s*)?[+-]?"# + decimal + #"\)|(?:"# + currency + #"\s*)?[+-]?"# + decimal + #"-?|"# + currency + #"\s*[+-]?[0-9]+))(?![\p{L}\p{N}.,])"#
    static let moneyRegex = try! NSRegularExpression(pattern: moneyTokenPattern, options: .caseInsensitive)

    static func parse(_ input: String) -> Decimal? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^[+-]?[0-9]{1,18}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    /// Only an actual printed numeric token is accepted. No OCR character substitution or guessing.
    static func printed(_ input: String) -> Decimal? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for symbol in ["A$", "AUD", "USD", "NZD", "EUR", "GBP", "CAD", "CHF", "JPY", "$", "€", "£", "¥"] {
            text = text.replacingOccurrences(of: symbol, with: "", options: .caseInsensitive)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.hasSuffix(")") { text = "-" + text.dropFirst().dropLast() }
        if text.hasSuffix("-") { text = "-" + text.dropLast() }
        if text.contains(",") {
            if text.contains(".") {
                // Unambiguous English grouping. Other formats stay missing for manual review.
                if text.range(of: #"^[+-]?[0-9]{1,3}(,[0-9]{3})+\.[0-9]{1,6}$"#, options: .regularExpression) != nil {
                    text = text.replacingOccurrences(of: ",", with: "")
                } else if text.range(of: #"^[+-]?[0-9]{1,3}(\.[0-9]{3})+,[0-9]{1,2}$"#, options: .regularExpression) != nil {
                    text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                } else { return nil }
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
