
import SwiftUI
import Observation

@MainActor
struct ReceiptSavingContext {
    let services: ReceiptLibraryServices
    let saveReceipt: SaveReceipt

    static var current: ReceiptSavingContext?
}

struct PolicyDraft: Identifiable, Equatable {
    enum WarrantyUnit: String, CaseIterable, Identifiable {
        case days = "Days"
        case months = "Months"
        case years = "Years"

        var id: String { rawValue }

        var maximum: Int {
            switch self {
            case .days: 3650
            case .months: 120
            case .years: 10
            }
        }
    }

    var id = UUID()
    var kind: SavedPolicy.Kind = .returns
    var title = ""
    var daysText = ""
    var notes = ""
    var applies = true

    var warrantyUnit: WarrantyUnit = .days
    var warrantyValue = 30

    init() {}

    init(_ policy: SavedPolicy) {
        id = policy.id
        kind = policy.kind
        title = policy.title
        daysText = String(policy.windowDays)
        notes = policy.notes

        if policy.kind == .warranty {
            warrantyUnit = .days
            warrantyValue = min(3650, max(1, policy.windowDays))
        }
    }

    var days: Int? {
        if kind == .warranty {
            guard (1...warrantyUnit.maximum).contains(warrantyValue) else {
                return nil
            }

            switch warrantyUnit {
            case .days:
                return warrantyValue
            case .months:
                return WarrantyLength.days(months: warrantyValue)
            case .years:
                return WarrantyLength.days(months: warrantyValue * 12)
            }
        }

        guard let value = Int(daysText.trimmingCharacters(in: .whitespaces)),
              (1...3650).contains(value) else {
            return nil
        }

        return value
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !cleanTitle.isEmpty && days != nil
    }

    var saved: SavedPolicy? {
        days.map {
            SavedPolicy(
                id: id,
                kind: kind,
                title: cleanTitle,
                windowDays: $0,
                notes: cleanNotes
            )
        }
    }

    var applied: AppliedPolicy? {
        days.map {
            AppliedPolicy(
                kind: kind,
                title: cleanTitle,
                windowDays: $0,
                notes: cleanNotes,
                sourcePolicyID: id
            )
        }
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

@MainActor
@Observable
final class ReceiptSaveViewModel {
    enum Phase: Equatable {
        case editing
        case saving
        case saved
        case attachFailed(String)
    }

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

    init(
        costs: ReceiptCostBreakdown,
        pages: [Data],
        source: ReceiptMetadata.ExtractionSource? = nil
    ) {
        let preferred = Locale.current.currency?.identifier ?? "AUD"

        currencies = Self.unique([
            preferred, "AUD", "USD", "EUR", "GBP", "NZD"
        ])

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

    // MARK: - Retailers and policies

    func loadRetailers() async {
        guard let context = ReceiptSavingContext.current else { return }

        do {
            savedRetailers = try await context.services.manageRetailers.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads a saved retailer and applies only the policies selected
    /// in the retailer browser.
    func applyRetailerChoice(
        _ saved: SavedRetailer,
        selectedPolicies: [SavedPolicy]
    ) {
        selectedRetailerID = saved.id
        selectedRetailerName = saved.name
        retailer = saved.name

        let selectedIDs = Set(selectedPolicies.map(\.id))

        policyDrafts = saved.policies.map { policy in
            var draft = PolicyDraft(policy)
            draft.applies = selectedIDs.contains(policy.id)
            return draft
        }
    }

    /// Typing the exact name of a saved retailer loads its default
    /// return policy. Other policies remain unapplied until selected.
    func retailerTextChanged() {
        let key = SavedRetailer.key(retailer)

        if let selected = selectedRetailerName {
            if SavedRetailer.key(selected) != key {
                selectedRetailerID = nil
                selectedRetailerName = nil
            }
            return
        }

        guard policyDrafts.isEmpty,
              !key.isEmpty,
              let match = savedRetailers.first(where: {
                  SavedRetailer.key($0.name) == key
              }) else {
            return
        }

        let defaultPolicies: [SavedPolicy]

        if let defaultID = match.defaultReturnPolicyID,
           let policy = match.policies.first(where: { $0.id == defaultID }) {
            defaultPolicies = [policy]
        } else {
            defaultPolicies = []
        }

        applyRetailerChoice(
            match,
            selectedPolicies: defaultPolicies
        )
    }

    func addPolicy() {
        policyDrafts.append(PolicyDraft())
    }

    func removePolicy(id: UUID) {
        policyDrafts.removeAll { $0.id == id }
    }

    private func rememberCurrentRetailer(
        using context: ReceiptSavingContext
    ) async throws {
        let saved = SavedRetailer(
            id: UUID(),
            name: retailer,
            policies: policyDrafts.compactMap(\.saved)
        )

        try await context.services.manageRetailers.save(saved)

        selectedRetailerID = saved.id
        selectedRetailerName = saved.name
        savedRetailers = try await context.services.manageRetailers.all()
    }

    // MARK: - Suggestions

    func suggestMetadataIfNeeded() async {
        guard !hasRequestedSuggestions else { return }

        hasRequestedSuggestions = true
        isSuggestingMetadata = true

        defer {
            isSuggestingMetadata = false
        }

        let names = costs.products.compactMap { product -> String? in
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || product.isReturn ? nil : name
        }

        guard let suggestion = await ReceiptMetadataSuggester.suggest(
            retailer: retailer.isEmpty ? "Unknown retailer" : retailer,
            itemNames: names,
            total: ReceiptAmountParser.parse(totalText) ?? costs.total ?? 0
        ) else {
            metadataSuggestionMessage =
                "Automatic suggestions require a supported Apple Intelligence device and iOS 26 or later. You can enter these manually."
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

    // MARK: - Saving

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

        // Only policies explicitly selected by the user are applied.
        appliedPolicies = policyDrafts
            .filter(\.applies)
            .compactMap(\.applied)

        guard let receipt = makeReceipt() else {
            errorMessage = "Enter a retailer and a valid total."
            return
        }

        phase = .saving

        do {
            if rememberRetailer && selectedRetailerID == nil {
                try await rememberCurrentRetailer(using: context)
            }

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
                receiptID: receiptID,
                costs: costs,
                source: source,
                pages: pages
            )

            let categoryValue = category.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

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

    /// Return reminders use the shortest selected return window.
    /// Warranties are stored with the receipt but do not create reminders.
    private func makeReceipt() -> PurchaseReceipt? {
        let name = retailer.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty,
              let total = ReceiptAmountParser.parse(totalText),
              total >= 0 else {
            return nil
        }

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
            returnPolicy: shortest.map {
                ReturnPolicy(
                    windowDays: $0.windowDays,
                    notes: $0.notes
                )
            }
        )
    }

    private static func items(
        from costs: ReceiptCostBreakdown
    ) -> [PurchasedItem] {
        costs.products.compactMap { product in
            let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !name.isEmpty,
                  !product.isReturn,
                  let line = product.lineTotal,
                  line >= 0 else {
                return nil
            }

            var quantity = 1

            if let printed = product.quantity {
                let whole = NSDecimalNumber(decimal: printed).intValue

                if whole > 1, Decimal(whole) == printed {
                    quantity = whole
                }
            }

            let unitPrice = quantity == 1
                ? line
                : (product.unitPrice ?? rounded(line / Decimal(quantity)))

            return PurchasedItem(
                name: name,
                quantity: quantity,
                unitPrice: unitPrice
            )
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

    init(
        costs: ReceiptCostBreakdown,
        pages: [Data],
        source: ReceiptMetadata.ExtractionSource? = nil
    ) {
        _model = State(
            initialValue: ReceiptSaveViewModel(
                costs: costs,
                pages: pages,
                source: source
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .saved {
                    savedView
                } else {
                    form
                }
            }
            .navigationTitle(model.phase == .saved ? "Saved" : "Save receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.phase == .saved ? "Close" : "Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .saving {
                        ProgressView()
                    } else if model.phase != .saved {
                        Button("Save") {
                            Task {
                                await model.save()
                            }
                        }
                        .disabled(!model.canSave)
                    }
                }
            }
            .disabled(model.phase == .saving)
            .interactiveDismissDisabled(model.phase == .saving)
            .task {
                await model.loadRetailers()
            }
            .task {
                await model.suggestMetadataIfNeeded()
            }
            .onChange(of: model.retailer) {
                model.retailerTextChanged()
            }
            .sheet(
                isPresented: $showingRetailers,
                onDismiss: {
                    Task {
                        await model.loadRetailers()
                    }
                }
            ) {
                RetailerBrowserView { saved, selectedPolicies in
                    model.applyRetailerChoice(
                        saved,
                        selectedPolicies: selectedPolicies
                    )
                }
            }
            .alert("Possible duplicate", isPresented: $model.showDuplicatePrompt) {
                Button("Save anyway") {
                    Task {
                        await model.save(ignoringDuplicates: true)
                    }
                }

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
            Button("Done") {
                dismiss()
            }
        }
    }

    private var form: some View {
        Form {
            Section("Receipt") {
                Button {
                    showingRetailers = true
                } label: {
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

                DatePicker(
                    "Purchase date",
                    selection: $model.date,
                    in: ...Date.now,
                    displayedComponents: .date
                )

                Picker("Profile", selection: $model.profile) {
                    ForEach(PurchaseProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue.capitalized)
                            .tag(profile)
                    }
                }
            }

            if let name = model.selectedRetailerName {
                Section {
                    Label(
                        "Policies from \(name). Select which ones apply to this receipt.",
                        systemImage: "storefront"
                    )
                    .font(.footnote)
                }
            }

            Section {
                ForEach($model.policyDrafts) { $draft in
                    if draft.kind == .returns {
                        PolicyEditor(draft: $draft) {
                            model.removePolicy(id: draft.id)
                        }
                    }
                }

                Button {
                    var draft = PolicyDraft()
                    draft.kind = .returns
                    draft.title = "Return policy"
                    draft.daysText = "30"
                    draft.applies = true
                    model.policyDrafts.append(draft)
                } label: {
                    Label("Add return policy", systemImage: "plus.circle")
                }
            } header: {
                Text("Return policies")
            } footer: {
                Text("Only selected return policies apply. Reminders use the shortest selected return window.")
            }

            Section {
                ForEach($model.policyDrafts) { $draft in
                    if draft.kind == .warranty {
                        PolicyEditor(draft: $draft) {
                            model.removePolicy(id: draft.id)
                        }
                    }
                }

                Button {
                    var draft = PolicyDraft()
                    draft.kind = .warranty
                    draft.title = "Warranty"
                    draft.warrantyValue = 12
                    draft.warrantyUnit = .months
                    draft.applies = true
                    model.policyDrafts.append(draft)
                } label: {
                    Label("Add warranty", systemImage: "plus.circle")
                }
            } header: {
                Text("Warranties")
            } footer: {
                Text("Only selected warranties are saved with this receipt. Warranty durations are stored as days.")
            }

            if model.selectedRetailerID == nil {
                Section {
                    Toggle(
                        "Remember this retailer and its policies",
                        isOn: $model.rememberRetailer
                    )
                }
            }

            Section {
                PolicyLiabilityNotice()
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
                    Label(
                        "Suggesting metadata on device…",
                        systemImage: "sparkles"
                    )
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
                    Text(
                        "The receipt was saved, but its scan details or metadata were not. \(message)"
                    )

                    Button("Try again") {
                        Task {
                            await model.retryAttach()
                        }
                    }

                    Button("Close without scan details") {
                        dismiss()
                    }
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
                        products: [
                            .init(
                                name: "Headphones",
                                quantity: 1,
                                unitPrice: 99,
                                lineTotal: 99
                            )
                        ],
                        total: 99
                    ),
                    pages: []
                )
            } else {
                ProgressView()
            }
        }
        .task {
            ready = (try? Self.installContext()) != nil
        }
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
