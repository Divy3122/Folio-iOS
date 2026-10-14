# Shared architecture

## Boundaries

Physical source root: `Folio/Folio/`.

- App: one @main entry point, startup view model and dependency composition.
- Domain/Models: Codable, Sendable value types, without SwiftUI or SwiftData.
- Domain/Repositories: receipt/reminder storage and OCR/extraction/scheduling interfaces.
- Domain/UseCases: validation, fetching, spending aggregation and reminder rules.
- Domain/Errors: typed recoverable errors.
- Data/Persistence: SwiftData records with versioned JSON payloads.
- Data/Repositories: mapping and durable saves, isolated on MainActor.
- Features: independent ReceiptScanner, ReceiptLibrary, SpendingDashboard and ReturnReminders directories.
- Core/Components and Core/Services: shared UI and framework adapters when needed.
- Resources: future shared resources; existing asset catalogue remains at the source root.

Dependency direction: SwiftUI view → observable view model → use case → domain repository protocol ← SwiftData adapter. The composition root injects concrete adapters. Views never query SwiftData directly. AppViewModel retains the live dependencies and exposes startup failure with retry, rather than destroying/replacing a failing store.

Domain values are Sendable. Repository protocols and use cases are explicitly MainActor isolated because their initial implementation uses SwiftData contexts. Each repository owns a dedicated context with autosave disabled and rollback on save failure. OCR/extraction services are Sendable async interfaces; implement expensive work off the main actor. Project-wide implicit MainActor isolation was replaced with explicit boundaries and complete concurrency checking.

## Contracts and business rules

PurchaseReceipt has a stable UUID, retailer, purchase date, ISO currency, Decimal total, purchased items, purchase profile and optional confirmed ReturnPolicy. Item totals need not equal the receipt total because of tax, discounts and rounding. SaveReceipt rejects blank retailer/item names, invalid currencies, negative/NaN prices, nonpositive quantities and invalid policy windows. Refunds/negative transactions are outside this initial purchase model.

FetchReceipts returns newest first with UUID tie-breaking. CalculateSpending uses a half-open date interval and returns separate totals per currency; no exchange-rate assumptions.

CreateReturnReminder loads an existing saved receipt, requires a positive confirmed policy window, computes a deadline using injected Calendar calendar-day arithmetic, and requires a notification time in the future and no later than that deadline. The current convention is purchase timestamp plus policy days; feature work must capture retailer-specific cutoffs/exceptions rather than present this convention as universal policy. Calendar and clock are injectable for deterministic tests. Reminder persistence and OS scheduling are deliberately separate operations. Notification denial must not delete a saved reminder; implement retry/reconciliation in the reminder feature.

Repository saves upsert by UUID. SwiftData stores versioned JSON payloads, keeping framework models private to Data. Unknown schema versions and corrupt payloads fail explicitly. Before changing persisted fields, add decode/migration tests and a migration strategy; never silently reset the store. Large datasets will require query/pagination interfaces instead of loading all receipts. Receipt images are not persisted by this foundation.

## Feature handoff

- Scanner owner: VisionKit capture with hardware/permission checks; Vision OCR adapter conforming to ReceiptTextRecognizing; optional Foundation Models adapter conforming to ReceiptExtracting. Check model availability at runtime, including eligible devices, downloaded model and user settings. On failure use Vision text and manual editing. ReceiptExtractionResult is untrusted candidate data; user confirmation precedes SaveReceipt. Do not silently save generated fields.
- Library owner: ReceiptLibrary view model uses FetchReceipts/SaveReceipt. Coordinate image lifecycle, deletion, search and migration contracts before extending shared repositories.
- Dashboard owner: consume CalculateSpending and render with Swift Charts. Do not combine currencies or duplicate persistence queries in views.
- Reminder owner: consume CreateReturnReminder; implement ReminderScheduling with UserNotifications, request permission in context, use UUID identifiers for idempotence, reconcile pending requests and expose denial/retry states.
- Integration owner: compose feature view models from DependencyContainer, shared navigation and accessibility. Do not add another app entry point.

Framework adapters and feature screens are intentionally not implemented here. A lower deployment target requires a separate compatibility change; the current project requires iOS 26.2 even where Apple Intelligence is unavailable.

## Privacy and release work

CloudKit is explicitly disabled. No network, analytics or receipt logging is added. Local storage still needs product decisions about backup, data protection, retention, deletion and image storage. Camera usage descriptions must be added when capture is integrated. Test real hardware, permission rejection, VoiceOver, large text, light/dark mode and storage failures before release. No retailer partnerships, statutory-rights interpretation or refund processing are implied.
