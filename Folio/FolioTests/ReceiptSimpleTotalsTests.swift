import Foundation
import Testing
@testable import Folio

struct ReceiptSimpleTotalsTests {
    @Test func printedShippingAndIncludedGSTAreCopied() {
        let text = """
        Page 1
        JB HI-FI Group Pty Ltd
        Apple AirPods Pro With MagSafe Charging Case 2nd Gen $349.00 x1 $349.00
        Subtotal $349.00
        Shipping $10.50
        Total amount paid $359.50
        Includes $31.73 GST
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "349"))
        #expect(amounts.total == Decimal(string: "359.50"))
        #expect(amounts.additionalFees == Decimal(string: "42.23"))
    }

    @Test func printedVATIsIncludedInCharges() {
        let text = """
        SUBTOTAL £66.20
        VAT 20% £13.24
        TOTAL £79.44
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "66.20"))
        #expect(amounts.total == Decimal(string: "79.44"))
        #expect(amounts.additionalFees == Decimal(string: "13.24"))
    }

    @Test func tipBlankTotalLineDoesNotOverrideTotalDue() {
        let text = """
        SUBTOTAL $70.85
        Tax $5.31
        TOTAL DUE $76.16
        TIP
        TOTAL
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.total == Decimal(string: "76.16"))
    }

    @Test func unrelatedNumbersDoNotBecomeSubtotal() {
        let text = """
        Product $349.00
        Shipping $10.50
        Includes $31.73 GST
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == nil)
        #expect(amounts.total == nil)
        #expect(amounts.additionalFees == Decimal(string: "42.23")) // Charges remain independent of missing totals.
    }

    @Test func decimalCommaDoesNotInventNegativeFee() {
        let text = """
        SUB-TOTAL €79,44
        GRAND TOTAL €66,20
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "79.44"))
        #expect(amounts.total == Decimal(string: "66.20"))
        #expect(amounts.additionalFees == nil) // No fee is printed; a difference is not a fee.
    }

    @Test func willowForkVatQualifierAndDecimalComma() {
        let text = """
        Page 1
        THE WILLOW FORK BISTRO
        Garlic Bread x2 £7,80
        Crispy Calamari £6,50
        Pan-Seared Salmon £17,90
        Ribeye Steak 21,50
        House Red £11,00
        Still Water £1,50
        Subtotal (excl. VAT): £66,20
        VAT (20%) £13,24
        Total £79,44
        """
        let amounts = ReceiptSimpleTotals.read(ocrText: text)
        #expect(amounts.subtotal == Decimal(string: "66.20"))
        #expect(amounts.total == Decimal(string: "79.44"))
        #expect(amounts.additionalFees == Decimal(string: "13.24"))
    }
}
