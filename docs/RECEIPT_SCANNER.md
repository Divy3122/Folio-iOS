# Structured receipt review

## Scope and entry point

Work is confined to `feature/receipt-scanner`. The existing VisionKit camera and Vision recognizer remain in use. `ReceiptScannerView` now presents a native SwiftUI form with exactly two primary sections:

1. Individual Product Cost Breakdown
2. Total Cost

Integration calls `ReceiptScannerView()` as before. The local temporary **Test Receipt Scanner** button in ContentView is not part of this feature commit. No navigation changes are required inside the feature.

All products and amounts are editable; products can be added/removed. Fractional quantities and signed return line costs are supported. Totals include subtotal, discounts, GST/tax, fees, rounding and the independent final total. Original OCR, images, warnings and local draft status are nested in Total Cost, not additional primary sections.

## Pipeline

1. The unchanged VisionKit flow supplies JPEG bytes for every scanned page.
2. ReceiptScannerViewModel retains the bytes and asks the existing ReceiptTextRecognizing service for each page. Page boundaries remain in the raw OCR. A failing page does not discard successful pages.
3. FoundationModelsReceiptExtractor implements the existing ReceiptExtracting protocol. It checks SystemLanguageModel availability and invokes LanguageModelSession with @Generable types and guided generation. There are no external AI APIs or network requests.
4. OCR is split into bounded chunks of at most 16 lines and approximately 2,400 characters, overlapping four lines. Each chunk uses a fresh session; global line numbers support wrapped products and merge overlap without collapsing repeated purchases on separate lines. Oversized single OCR lines can still exceed model limits and use manual fallback.
5. Generated prices are printed strings, not floating-point values. ReceiptExtractionMapper verifies source quotes and numeric tokens, then parses them strictly into Decimal. Unsupported fields stay nil. Separate fee rows are added using Decimal and deduplicated by source line. Conflicting printed summary amounts across chunks stay missing rather than choosing a convenient total.
6. The additive ReceiptExtractionResult.costBreakdown holds the unverified data. PurchaseReceipt/PurchasedItem and repository protocols are unchanged. A saved PurchaseReceipt requires retailer/date/currency and nonoptional purchase values that OCR may not supply; this screen deliberately does not invent them or call SaveReceipt. Its candidate remains nil. Library save integration is separate work.
7. ReceiptReviewDraft holds editable strings so invalid edits remain visible. ReceiptCostValidator checks numeric validity, quantities, sign/return consistency, product arithmetic, tax/discount treatment, subtotal and total reconciliation. Reconciliation uses a 0.01 tolerance. Warnings never rewrite the total. Currency-specific precision rules remain future integration work.
8. The view model applies an extraction result only when the edit revision is unchanged. Editing any field while processing keeps the entire edited draft intact; automatic results are not merged over it.

Guided generation guarantees a schema, not OCR/model accuracy. Evidence checking rejects unsupported literal values but cannot prove that every number was assigned to the correct field or that every product was found. Every result remains an unverified review requiring comparison with the originals.

## Tax, discounts and missing data

Tax can be included, added or unknown. Included tax is not added again. Discounts can already be included in final line costs or deducted separately. Unknown treatment with a nonzero adjustment prevents a confident reconciliation. Missing summary adjustments are treated as absent for the provisional comparison; extraction warnings still identify incomplete pages/fields. Product-specific discounts are reflected in the final line cost and checked against quantity × unit price, rather than deducted again at receipt level.

Line-cost totals can legitimately differ from quantity × unit price due to discounts or rounding. The user sees a warning and can correct the relevant field. Signed returns, fees and rounding are included in the total comparison. Neither a missing final total nor a mismatch is repaired by summing products.

Unknown quantities and prices stay blank, not 1 or zero. Ambiguous tokens such as `1,234`, malformed OCR such as `3.OO`, unsupported locale formats and model context/guardrail failures require manual review. Abbreviations are preserved instead of expanded with invented names. This is retailer-independent extraction, not a guarantee of perfect interpretation of every receipt layout or language.

## Retention and failure handling

The scanner saves one local review draft at Application Support/ReceiptScanner/review.json, including original JPEG bytes, raw OCR, edits and warnings. Writes are atomic with file protection until first authentication; the directory is excluded from backup. No real receipt text or images are logged. The view model owns persistence, never the view or SwiftData.

Drafts are saved after processing and debounced edits, and on background/dismiss. Storage failures are visible with retry. An abrupt process kill before a pending write completes can lose the latest edit. The most recently completed local snapshot is restored on reopen. A completed new scan replaces the single draft only after an explicit confirmation; cancelling the camera preserves it. This is draft retention, not receipt-library persistence or a multi-receipt archive.

Unavailable Apple Intelligence, failed chunks, cancellation or unreadable OCR leave an empty/partial editable form and retain the original data. No successful extraction is fabricated. Partial results carry warnings identifying the failed OCR range.

## Validation and tests

Run the actual project tests:

```sh
xcodebuild -project Folio/Folio.xcodeproj -scheme Folio \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FolioTests CODE_SIGNING_ALLOWED=NO test
```

ReceiptExtractionTests uses deterministic generated-output fixtures and injectable recognizer/generator failures. It covers retail receipts, metadata exclusion, wrapped products, multipliers/fractional quantities, repeated purchases, discounts, included and added GST, returns/fees/rounding, missing and unsupported numbers, mismatched totals, unavailable models, extraction failures, multi-page OCR, overlapping chunks, conflicting summaries, late edits, cancellation and local draft round trips. Existing shared-domain tests remain in the test run. These tests do **not** measure live Foundation Models extraction quality.

## Physical receipt test checklist

1. Use Xcode 26.2+ and an iPhone running iOS 26.2+. Choose your signing team and run Folio. Use the existing local scanner testing button or present ReceiptScannerView from your integration module.
2. Open Scan Receipt and allow camera access. Scan every page of one receipt before tapping Save in the camera. Do not combine unrelated transactions in one scan.
3. On an Apple Intelligence-capable device with its model ready, compare every generated product and final total with the printed receipt. Test a supermarket receipt, an abbreviated/wrapped receipt, repeated products and a two-page receipt.
4. Test receipt-wide discounts, product discounts, GST-inclusive wording, added tax, multiple fees, a return and cash tender/change. Check the tax/discount pickers and confirm no metadata appears as a product.
5. Cover a price/total before scanning. Confirm missing values remain blank and the final total is not computed. Correct amounts, add/remove products and intentionally introduce a mismatch to see warnings.
6. Edit the form while extraction is in progress. Confirm your edits survive completion. Stop processing and confirm images/OCR remain available.
7. Disable Apple Intelligence or use an unsupported device. Confirm a clear availability warning and usable manual form with the OCR and scans retained.
8. Close/reopen the scanner and relaunch the app after draft saving. Confirm edits and originals restore. Test large Dynamic Type, VoiceOver and both appearances on device.

Camera capture and real Apple Intelligence accuracy must be tested on physical hardware; simulator/mock results are not a substitute.

## Presentation explanation

“VisionKit captures receipt pages and Vision turns them into text. An on-device Foundation Models service uses guided generation to propose a typed cost breakdown. The mapper checks source evidence and converts printed prices to Decimal, preserving unknowns. A separate validator checks the arithmetic without altering the receipt's final total. SwiftUI displays two editable sections through an observable view model. If AI is unavailable or wrong, manual review still works with the original OCR and images. Tests isolate business rules and failure paths from the nondeterministic model.”

Apple API reference: https://developer.apple.com/documentation/foundationmodels/languagemodelsession
