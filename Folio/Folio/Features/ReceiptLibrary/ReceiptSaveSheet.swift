import SwiftUI
import Observation

@MainActor
struct ReceiptSavingContext {
    let services: ReceiptLibraryServices
    let saveReceipt: SaveReceipt

    static var current: ReceiptSavingContext?
}

@MainActor @Observable
final class ReceiptSaveViewModel {
    enum Phase: Equatable { case editing, saving, saved, attachFailed(String) }

    var retailer = ""
    var date = Date.now
    var currency: String
    var profile: PurchaseProfile = .personal
    var totalText: String
    var category = ""
    var tagsText = ""
    var showDuplicatePrompt = false
    private(set) var isSuggestingMetadata = false
    private(set) var metadataSuggestionMessage: String?

    private(set) var phase: Phase = .editing
    private(set) var errorMessage: String?
    let currencies: [String]

    private let receiptID = UUID()
    private let costs: ReceiptCostBreakdown
    private let pages: [Data]
    private let source: ReceiptMetadata.ExtractionSource?
    private var hasRequestedSuggestions = false

    init(costs: ReceiptCostBreakdown, pages: [Data], source: ReceiptMetadata.ExtractionSource? = nil) {
        let preferred = Locale.current.currency?.identifier ?? "AUD"
        currencies = Self.unique([preferred, "AUD", "USD", "EUR", "GBP", "NZD"])
        currency = preferred
        totalText = ReceiptAmountParser.text(costs.total)
        self.costs = costs
        self.pages = pages
        self.source = source ?? (pages.isEmpty ? .manual : nil)
    }

    var canSave: Bool {
        !retailer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ReceiptAmountParser.parse(totalText) != nil
    }

    func suggestMetadataIfNeeded() async {
        guard !hasRequestedSuggestions else { return }
        hasRequestedSuggestions = true
        isSuggestingMetadata = true
        defer { isSuggestingMetadata = false }

        let names = costs.products.compactMap { product -> String? in
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || product.isReturn ? nil : name
        }
        guard let suggestion = await ReceiptMetadataSuggester.suggest(
            retailer: retailer.isEmpty ? "Unknown retailer" : retailer,
            itemNames: names,
            total: costs.total!
        ) else {
            metadataSuggestionMessage = "Automatic suggestions require a supported Apple Intelligence device and iOS 26 or later. You can enter these manually."
            return
        }

        if category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            category = suggestion.category
        }
        if tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tagsText = suggestion.tags.joined(separator: ", ")
        }
        metadataSuggestionMessage = "Suggestions are ready. Review them before saving."
    }

    func resetMetadataSuggestionRequest() {
        hasRequestedSuggestions = false
        metadataSuggestionMessage = nil
    }

    func save(ignoringDuplicates: Bool = false) async {
        errorMessage = nil
        guard let context = ReceiptSavingContext.current else {
            errorMessage = "Receipt storage isn't available."
            return
        }
        guard let receipt = makeReceipt() else {
            errorMessage = "Enter a retailer and a valid total."
            return
        }
        phase = .saving
        do {
            if !ignoringDuplicates {
                let duplicates = try await context.services.detectDuplicate(receipt)
                if !duplicates.isEmpty {
                    showDuplicatePrompt = true
                    phase = .editing
                    return
                }
            }
            try await context.saveReceipt(receipt)
        } catch {
            errorMessage = error.localizedDescription
            phase = .editing
            return
        }
        await attachDetails(using: context)
    }

    func retryAttach() async {
        guard let context = ReceiptSavingContext.current else { return }
        phase = .saving
        await attachDetails(using: context)
    }

    private func attachDetails(using context: ReceiptSavingContext) async {
        do {
            try await context.services.attachDetails(
                receiptID: receiptID, costs: costs, source: source, pages: pages
            )
            let categoryValue = category.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = tagsText
                .split { $0 == "," || $0 == "\n" }
                .map(String.init)
            try await context.services.updateMetadata(id: receiptID) { metadata in
                metadata.category = categoryValue
                metadata.tags = UpdateReceiptMetadata.normalised(tags)
            }
            phase = .saved
        } catch {
            phase = .attachFailed(error.localizedDescription)
        }
    }

    private func makeReceipt() -> PurchaseReceipt? {
        let name = retailer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let total = ReceiptAmountParser.parse(totalText), total >= 0 else { return nil }
        return PurchaseReceipt(
            id: receiptID,
            retailer: Retailer(name: name),
            purchasedAt: date,
            currencyCode: currency,
            total: total,
            items: Self.items(from: costs),
            profile: profile
        )
    }

    private static func items(from costs: ReceiptCostBreakdown) -> [PurchasedItem] {
        costs.products.compactMap { product in
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !product.isReturn, let line = product.lineTotal, line >= 0 else { return nil }
            var quantity = 1
            if let printed = product.quantity {
                let whole = NSDecimalNumber(decimal: printed).intValue
                if whole > 1, Decimal(whole) == printed { quantity = whole }
            }
            let unitPrice = quantity == 1 ? line : (product.unitPrice ?? rounded(line / Decimal(quantity)))
            return PurchasedItem(name: name, quantity: quantity, unitPrice: unitPrice)
        }
    }

    private static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 4, .plain)
        return output
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct ReceiptSaveSheet: View {
    @State private var model: ReceiptSaveViewModel
    @Environment(\.dismiss) private var dismiss

    init(costs: ReceiptCostBreakdown, pages: [Data], source: ReceiptMetadata.ExtractionSource? = nil) {
        _model = State(initialValue: ReceiptSaveViewModel(costs: costs, pages: pages, source: source))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .saved { savedView } else { form }
            }
            .navigationTitle(model.phase == .saved ? "Saved" : "Save receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.phase == .saved ? "Close" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .saving {
                        ProgressView()
                    } else if model.phase != .saved {
                        Button("Save") { Task { await model.save() } }
                            .disabled(!model.canSave)
                    }
                }
            }
            .disabled(model.phase == .saving)
            .interactiveDismissDisabled(model.phase == .saving)
            .task { await model.suggestMetadataIfNeeded() }
            .alert("Possible duplicate", isPresented: $model.showDuplicatePrompt) {
                Button("Save anyway") { Task { await model.save(ignoringDuplicates: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A receipt with the same retailer, date and total is already saved.")
            }
        }
    }

    private var savedView: some View {
        ContentUnavailableView {
            Label("Receipt saved", systemImage: "checkmark.circle")
        } description: {
            Text("Find it in the Receipts tab.")
        } actions: {
            Button("Done") { dismiss() }
        }
    }

    private var form: some View {
        Form {
            Section("Receipt") {
                TextField("Retailer", text: $model.retailer)
                    .textInputAutocapitalization(.words)
                DatePicker("Purchase date", selection: $model.date, in: ...Date.now, displayedComponents: .date)
                Picker("Profile", selection: $model.profile) {
                    ForEach(PurchaseProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue.capitalized).tag(profile)
                    }
                }
            }

            Section("Amount") {
                Picker("Currency", selection: $model.currency) {
                    ForEach(model.currencies, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                TextField("Total", text: $model.totalText)
                    .keyboardType(.decimalPad)
            }

            Section("Category and tags") {
                TextField("Category", text: $model.category)
                    .textInputAutocapitalization(.words)
                TextField("Tags, separated by commas", text: $model.tagsText)
                    .textInputAutocapitalization(.words)
                if model.isSuggestingMetadata {
                    Label("Suggesting metadata on device…", systemImage: "sparkles")
                } else if let message = model.metadataSuggestionMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Suggest again") {
                    Task {
                        model.resetMetadataSuggestionRequest()
                        await model.suggestMetadataIfNeeded()
                    }
                }
                .disabled(model.isSuggestingMetadata)
            }

            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if case .attachFailed(let message) = model.phase {
                Section {
                    Text("The receipt was saved, but its scan details or metadata were not. \(message)")
                    Button("Try again") { Task { await model.retryAttach() } }
                    Button("Close without scan details") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
import SwiftData

private struct ReceiptSavePreviewHost: View {
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                ReceiptSaveSheet(
                    costs: ReceiptCostBreakdown(
                        products: [.init(name: "Headphones", quantity: 1, unitPrice: 99, lineTotal: 99)],
                        total: 99
                    ),
                    pages: []
                )
            } else {
                ProgressView()
            }
        }
        .task { ready = (try? Self.installContext()) != nil }
    }

    private static func installContext() throws {
        let container = try ModelContainer(
            for: StoredReceipt.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SwiftDataReceiptRepository(container: container)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceiptSavePreview-\(UUID().uuidString)")
        let services = ReceiptLibraryServices(
            repository: repository,
            images: try FileReceiptImageStore(root: folder)
        )
        ReceiptSavingContext.current = ReceiptSavingContext(
            services: services,
            saveReceipt: SaveReceipt(repository: repository)
        )
    }
}
#endif
