import FoundationModels

// Strings preserve printed decimal tokens: no binary floating-point prices enter the pipeline.
@Generable
struct GeneratedReceiptAmount: Sendable {
    @Guide(description: "Exact printed numeric token, including sign/currency if present. Never calculate or repair OCR.")
    var printed: String
    @Guide(description: "Exact contiguous OCR quote containing the label and numeric token, without line-number prefixes.")
    var evidence: String
}

@Generable
struct GeneratedReceiptProduct: Sendable {
    @Guide(description: "Global line number where this product starts. Use the supplied line numbers.")
    var sourceLine: Int
    @Guide(description: "Product name as printed, keeping abbreviations. Join wrapped name lines with spaces. Do not expand or invent words.")
    var name: String
    @Guide(description: "Exact contiguous OCR excerpt containing this product and its amounts; omit supplied line-number prefixes.")
    var evidence: String
    @Guide(description: "Printed quantity token only, or nil if absent. Do not assume quantity 1. May be fractional for weighed goods.")
    var quantity: String?
    @Guide(description: "Printed per-unit price token only; nil if absent. Never divide the line cost to infer it.")
    var unitPrice: String?
    @Guide(description: "Printed final line cost token, after product-specific discounts where shown; nil if unreadable. Negative for printed returns only.")
    var lineTotal: String?
    @Guide(description: "Printed product-specific discount token as a positive amount, or nil. Never infer a discount.")
    var discount: String?
    @Guide(description: "True only if the OCR explicitly identifies this product as a return or refund.")
    var isReturn: Bool
}

@Generable
struct GeneratedReceiptFee: Sendable {
    @Guide(description: "Global line number of this fee. Do not include a combined fee summary as well as its components.")
    var sourceLine: Int
    var amount: GeneratedReceiptAmount
}

@Generable
struct GeneratedReceiptCosts: Sendable {
    @Generable enum TaxTreatment: Sendable { case included, added, unknown }
    @Generable enum DiscountTreatment: Sendable { case includedInLines, deductedFromLines, unknown }

    @Guide(description: "Every actual product separately, including returns. Exclude totals, payment methods, tender, change, loyalty, tax headings and transaction metadata. Do not deduplicate repeated purchases.")
    var products: [GeneratedReceiptProduct]
    var subtotal: GeneratedReceiptAmount?
    @Guide(description: "Receipt-wide discounts if explicitly printed; not a computed sum of product discounts. Nil when absent.")
    var discounts: GeneratedReceiptAmount?
    var tax: GeneratedReceiptAmount?
    @Guide(description: "Each explicitly printed additional fee separately, including bag fees and surcharges. Empty if absent. Exclude fees already represented as purchased products.")
    var fees: [GeneratedReceiptFee]
    var rounding: GeneratedReceiptAmount?
    @Guide(description: "Explicit final transaction total paid, not cash tendered, change, balance or subtotal. Nil if missing. Never sum products to obtain it.")
    var total: GeneratedReceiptAmount?
    @Guide(description: "Whether tax is included in line prices or added separately. Unknown unless explicitly supported.")
    var taxTreatment: TaxTreatment
    @Guide(description: "Whether receipt-wide discounts are already reflected in final line costs or need deducting. Unknown unless explicitly supported.")
    var discountTreatment: DiscountTreatment
}
