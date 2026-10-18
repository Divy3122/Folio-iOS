import SwiftUI
import Observation

@MainActor
struct ReceiptSavingContext {
    let services: ReceiptLibraryServices
    let saveReceipt: SaveReceipt

    static var current: ReceiptSavingContext?
}

struct PolicyDraft: Identifiable, Equatable {
    var id = UUID()
    var kind: SavedPolicy.Kind = .returns
    var title = ""
    var daysText = ""
    var notes = ""
    var applies = true

    init() {}

    init(_ policy: SavedPolicy) {
        id = policy.id
        kind = policy.kind
        title = policy.title
        daysText = String(policy.windowDays)
        notes = policy.notes
    }

    var days: Int? {
        guard let value = Int(daysText.trimmingCharacters(in: .whitespaces)), (1...3650).contains(value) else {
            return nil
        }
        return value
    }

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool { !cleanTitle.isEmpty && days != nil }

    var saved: SavedPolicy? {
        days.map { SavedPolicy(id: id, kind: kind, title: cleanTitle, windowDays: $0, notes: cleanNotes) }
    }

    var applied: AppliedPolicy? {
        days.map { AppliedPolicy(kind: kind, title: cleanTitle, windowDays: $0, notes: cleanNotes, sourcePolicyID: id) }
    }
}

extension SavedPolicy.Kind {
    var label: String {
        switch self {
        case .returns: "Return"
        case .warranty: "Warranty"
        }
    }
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
    var policyDrafts: [PolicyDraft] = []
    var rememberRetailer = true
    var showDuplicatePrompt = false
    private(set) var isSuggestingMetadata = false
    private(set) var metadataSuggestionMessage: String?
    private(set) var savedRetailers: [SavedRetailer] = []
    private(set) var selectedRetailerID: UUID?
    private(set) var selectedRetailerName: String?

    private(set) var phase: Phase = .editing
    private(set) var errorMessage: String?
    let currencies: [String]

    private let receiptID = UUID()
    private let costs: ReceiptCostBreakdown
    private let pages: [Data]
    private let source: ReceiptMetadata.ExtractionSource?
    private var hasRequestedSuggestions = false
    private var appliedPolicies: [AppliedPolicy] = []

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

    // MARK: Retailers and policies

    func loadRetailers() async {
        guard let context = ReceiptSavingContext.current else { return }
        do { savedRetailers = try await context.services.manageRetailers.all() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Fills the form from a saved retailer: only the chosen return policy and the warranty length apply.
    func applyRetailerChoice(_ saved: SavedRetailer, returnPolicyID: UUID?, warrantyMonths: Int) {
        selectedRetailerID = saved.id
        selectedRetailerName = saved.name
        retailer = saved.name

        var drafts = saved.policies.map(PolicyDraft.init)
        for index in drafts.indices {
            switch drafts[index].kind {
            case .returns: drafts[index].applies = drafts[index].id == returnPolicyID
            case .warranty: drafts[index].applies = false
            }
        }
        if warrantyMonths > 0 {
            let days = String(WarrantyLength.days(months: warrantyMonths))
            if let index = drafts.firstIndex(where: { $0.kind == .warranty }) {
                drafts[index].daysText = days
                drafts[index].applies = true
            } else {
                var warranty = PolicyDraft()
                warranty.kind = .warranty
                warranty.title = "Warranty"
                warranty.daysText = days
                drafts.append(warranty)
            }
        }
        policyDrafts = drafts
    }

    /// Typing the exact name of a saved retailer loads it, unless policies were already entered by hand.
    func retailerTextChanged() {
        let key = SavedRetailer.key(retailer)
        if let selected = selectedRetailerName {
            if SavedRetailer.key(selected) != key {
                selectedRetailerID = nil
                selectedRetailerName = nil
            }
            return
        }
        guard policyDrafts.isEmpty, !key.isEmpty,
              let match = savedRetailers.first(where: { SavedRetailer.key($0.name) == key }) else { return }
        applyRetailerChoice(match, returnPolicyID: match.defaultReturnPolicyID, warrantyMonths: match.defaultWarrantyMonths)
    }

    func addPolicy() { policyDrafts.append(PolicyDraft()) }

    func removePolicy(id: UUID) { policyDrafts.removeAll { $0.id == id } }

    private func rememberCurrentRetailer(using context: ReceiptSavingContext) async throws {
        let id = UUID()
        let saved = SavedRetailer(id: id, name: retailer, policies: policyDrafts.compactMap(\.saved))
        try await context.services.manageRetailers.save(saved)
        selectedRetailerID = id
        selectedRetailerName = retailer
        savedRetailers = try await context.services.manageRetailers.all()
    }

    // MARK: Suggestions

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
            total: ReceiptAmountParser.parse(totalText) ?? costs.total ?? 0
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

    // MARK: Saving

    func save(ignoringDuplicates: Bool = false) async {
        errorMessage = nil
        guard let context = ReceiptSavingContext.current else {
            errorMessage = "Receipt storage isn't available."
            return
        }
        guard policyDrafts.allSatisfy(\.isValid) else {
            errorMessage = RetailerError.invalidPolicy.localizedDescription
            return
        }
        appliedPolicies = policyDrafts.filter(\.applies).compactMap(\.applied)
        guard let receipt = makeReceipt() else {
            errorMessage = "Enter a retailer and a valid total."
            return
        }
        phase = .saving
        do {
            if rememberRetailer && selectedRetailerID == nil { try await rememberCurrentRetailer(using: context) }
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
            let policies = appliedPolicies
            try await context.services.updateMetadata(id: receiptID) { metadata in
                metadata.category = categoryValue
                metadata.tags = UpdateReceiptMetadata.normalised(tags)
                metadata.policies = policies
            }
            phase = .saved
        } catch {
            phase = .attachFailed(error.localizedDescription)
        }
    }

    /// Reminders use the shortest return window that applies; warranties are kept with the receipt only.
    private func makeReceipt() -> PurchaseReceipt? {
        let name = retailer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let total = ReceiptAmountParser.parse(totalText), total >= 0 else { return nil }
        let returns = appliedPolicies.filter { $0.kind == .returns }
        let shortest = returns.min { $0.windowDays < $1.windowDays }
        return PurchaseReceipt(
            id: receiptID,
            retailer: Retailer(name: name),
            purchasedAt: date,
            currencyCode: currency,
            total: total,
            items: Self.items(from: costs),
            profile: profile,
            returnPolicy: shortest.map { ReturnPolicy(windowDays: $0.windowDays, notes: $0.notes) }
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
    @State private var showingRetailers = false
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
            .task { await model.loadRetailers() }
            .task { await model.suggestMetadataIfNeeded() }
            .onChange(of: model.retailer) { model.retailerTextChanged() }
            .sheet(isPresented: $showingRetailers, onDismiss: { Task { await model.loadRetailers() } }) {
                RetailerBrowserView { saved, returnPolicyID, warrantyMonths in
                    model.applyRetailerChoice(saved, returnPolicyID: returnPolicyID, warrantyMonths: warrantyMonths)
                }
            }
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
                Button { showingRetailers = true } label: {
                    HStack {
                        Label("Saved retailers", systemImage: "storefront")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                TextField("Retailer", text: $model.retailer)
                    .textInputAutocapitalization(.words)
                DatePicker("Purchase date", selection: $model.date, in: ...Date.now, displayedComponents: .date)
                Picker("Profile", selection: $model.profile) {
                    ForEach(PurchaseProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue.capitalized).tag(profile)
                    }
                }
            }

            Section {
                if let name = model.selectedRetailerName {
                    Label("Policies from \(name). Adjust them for this receipt below.", systemImage: "storefront")
                        .font(.footnote)
                }
                ForEach($model.policyDrafts) { $draft in
                    PolicyEditor(draft: $draft) { model.removePolicy(id: draft.id) }
                }
                Button { model.addPolicy() } label: {
                    Label("Add policy", systemImage: "plus.circle")
                }
                if model.selectedRetailerID == nil {
                    Toggle("Remember this retailer and its policies", isOn: $model.rememberRetailer)
                }
                PolicyLiabilityNotice()
            } header: {
                Text("Return and warranty policies")
            } footer: {
                Text("Policies you apply are stored with this receipt. Return reminders use the shortest return window you apply.")
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
