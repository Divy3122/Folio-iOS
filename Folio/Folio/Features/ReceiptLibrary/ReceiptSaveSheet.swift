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
    var policyDrafts: [PolicyDraft] = []
    var rememberRetailer = true
    var showDuplicatePrompt = false

    private(set) var notificationsAllowed = true
    private(set) var isSuggestingMetadata = false
    private(set) var metadataSuggestionMessage: String?
    private(set) var savedRetailers: [SavedRetailer] = []
    private(set) var selectedRetailerID: UUID?
    private(set) var selectedRetailerName: String?
    private(set) var phase: Phase = .editing
    private(set) var errorMessage: String?
    let currencies: [String]

    let isEditingExistingRecord: Bool
    private let receiptID: UUID
    private let costs: ReceiptCostBreakdown
    private let pages: [Data]
    private let source: ReceiptMetadata.ExtractionSource?
    private var hasRequestedSuggestions = false
    private var appliedPolicies: [AppliedPolicy] = []

    init(costs: ReceiptCostBreakdown, pages: [Data], source: ReceiptMetadata.ExtractionSource? = nil, existingRecord: ReceiptRecord? = nil) {
        let preferred = Locale.current.currency?.identifier ?? "AUD"
        var seen = Set<String>()
        currencies = [preferred, "AUD", "USD", "EUR", "GBP", "NZD"].filter { seen.insert($0).inserted }
        currency = preferred
        
        if let existingRecord {
            self.isEditingExistingRecord = true
            self.receiptID = existingRecord.id
            let r = existingRecord.receipt
            self.retailer = r.retailer.name
            self.date = r.purchasedAt
            self.currency = r.currencyCode
            self.profile = r.profile
            self.totalText = ReceiptAmountParser.text(r.total)
            self.category = existingRecord.metadata.category
            self.tagsText = existingRecord.metadata.tags.joined(separator: ", ")
            
            self.policyDrafts = existingRecord.metadata.policies.map { applied in
                let saved = SavedPolicy(kind: applied.kind, title: applied.title, windowDays: applied.windowDays, notes: applied.notes)
                var draft = PolicyDraft(saved)
                draft.title = applied.title
                draft.applies = true
                return draft
            }
        } else {
            self.isEditingExistingRecord = false
            self.receiptID = UUID()
            self.totalText = ReceiptAmountParser.text(costs.total)
        }

        self.costs = costs
        self.pages = pages
        self.source = source ?? (pages.isEmpty && !isEditingExistingRecord ? .manual : nil)
    }

    var hasInvalidPolicyDrafts: Bool {
        policyDrafts.contains { $0.isEditing && !$0.isValid }
    }

    var canSave: Bool {
        !retailer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && ReceiptAmountParser.parse(totalText) != nil
        && !hasInvalidPolicyDrafts
    }

    var hasActiveRemindersSet: Bool {
        policyDrafts.contains { $0.applies && $0.setReminder }
    }

    // MARK: - Policy Helpers

    private func finalizePolicyDrafts() -> Bool {
        for index in policyDrafts.indices {
            if policyDrafts[index].isEditing {
                if policyDrafts[index].isValid {
                    policyDrafts[index].isConfirmed = true
                    policyDrafts[index].isEditing = false
                } else {
                    return false
                }
            }
        }
        return true
    }

    // MARK: Retailers and policies

    func loadRetailers() async {
        guard let context = ReceiptSavingContext.current else { return }
        do { savedRetailers = try await context.services.manageRetailers.all() }
        catch { errorMessage = error.localizedDescription }
    }

    func applyRetailerChoice(_ saved: SavedRetailer, selectedPolicies: [SavedPolicy]) {
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

    func retailerTextChanged() {
        let key = SavedRetailer.key(retailer)
        if let selected = selectedRetailerName {
            if SavedRetailer.key(selected) != key {
                selectedRetailerID = nil
                selectedRetailerName = nil
                policyDrafts = []
            }
            return
        }
        guard policyDrafts.isEmpty, !key.isEmpty,
              let match = savedRetailers.first(where: { SavedRetailer.key($0.name) == key }) else { return }
        applyRetailerChoice(match, selectedPolicies: [])
    }

    private func rememberCurrentRetailer(using context: ReceiptSavingContext) async throws {
        let saved = SavedRetailer(name: retailer, policies: policyDrafts.compactMap(\.saved))
        try await context.services.manageRetailers.save(saved)
        selectedRetailerID = saved.id
        selectedRetailerName = saved.name
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
        if category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { category = suggestion.category }
        if tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tagsText = suggestion.tags.joined(separator: ", ") }
        metadataSuggestionMessage = "Suggestions are ready. Review them before saving."
    }

    func resetMetadataSuggestionRequest() {
        hasRequestedSuggestions = false
        metadataSuggestionMessage = nil
    }

    // MARK: - Saving / Updating

    func save(ignoringDuplicates: Bool = false) async {
        errorMessage = nil
        guard let context = ReceiptSavingContext.current else {
            errorMessage = "Receipt storage isn't available."
            return
        }
        guard finalizePolicyDrafts() else {
            errorMessage = "Please complete or remove open policy drafts first."
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
            
            // Skip duplicate detection when updating an existing record
            if !isEditingExistingRecord && !ignoringDuplicates, !(try await context.services.detectDuplicate(receipt)).isEmpty {
                showDuplicatePrompt = true
                phase = .editing
                return
            }
            
            if isEditingExistingRecord {
                try await context.services.updateReceipt(receipt)
            } else {
                try await context.saveReceipt(receipt)
            }

            // MARK: - Per-Policy Reminder Scheduling
            let activeReminderDrafts = policyDrafts.filter { $0.applies && $0.setReminder }
            
            if let reminderRepo = context.services.reminders {
                // Clear old scheduled reminders for this receipt if updating
                if isEditingExistingRecord {
                    if let existingReminders = try? await reminderRepo.fetchAll() {
                        for r in existingReminders where r.receiptID == receiptID {
                            try? await reminderRepo.delete(id: r.id)
                            await context.services.scheduler?.cancel(id: r.id)
                        }
                    }
                }

                if !activeReminderDrafts.isEmpty {
                    var requestedAuth = false
                    var authGranted = true

                    for draft in activeReminderDrafts {
                        guard let deadline = draft.deadline(from: date), deadline > Date.now else { continue }
                        let reminder = ReturnReminder(receiptID: receiptID, deadline: deadline, notifyAt: draft.reminderDate)

                        do {
                            try await reminderRepo.save(reminder)

                            if let scheduler = context.services.scheduler {
                                if !requestedAuth {
                                    authGranted = try await scheduler.requestAuthorization()
                                    requestedAuth = true
                                }
                                if authGranted {
                                    try await scheduler.schedule(reminder)
                                }
                            }
                        } catch {
                            // Non-fatal reminder failure
                        }
                    }
                    notificationsAllowed = authGranted
                }
            }
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
            if !pages.isEmpty {
                try await context.services.attachDetails(receiptID: receiptID, costs: costs, source: source, pages: pages)
            }
            
            let categoryValue = category.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = tagsText.split { $0 == "," || $0 == "\n" }.map(String.init)
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

    private func makeReceipt() -> PurchaseReceipt? {
        let name = retailer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let total = ReceiptAmountParser.parse(totalText), total >= 0 else { return nil }
        let shortest = appliedPolicies.filter { $0.kind == .returns }.min { $0.windowDays < $1.windowDays }
        return PurchaseReceipt(
            id: receiptID, retailer: Retailer(name: name), purchasedAt: date, currencyCode: currency, total: total,
            items: Self.items(from: costs), profile: profile,
            returnPolicy: shortest.map { ReturnPolicy(windowDays: $0.windowDays, notes: $0.notes) })
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
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, 4, .plain)
        return output
    }
}

struct ReceiptSaveSheet: View {
    @State private var model: ReceiptSaveViewModel
    @State private var showingRetailers = false
    @Environment(\.dismiss) private var dismiss

    init(costs: ReceiptCostBreakdown, pages: [Data], source: ReceiptMetadata.ExtractionSource? = nil, existingRecord: ReceiptRecord? = nil) {
        _model = State(initialValue: ReceiptSaveViewModel(costs: costs, pages: pages, source: source, existingRecord: existingRecord))
    }

    var body: some View {
        NavigationStack {
            Group { if model.phase == .saved { savedView } else { form } }
                .navigationTitle(model.phase == .saved ? (model.isEditingExistingRecord ? "Updated" : "Saved") : (model.isEditingExistingRecord ? "Edit receipt" : "Save receipt"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.phase == .saved ? "Close" : "Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.phase == .saving {
                            ProgressView()
                        } else if model.phase != .saved {
                            Button(model.isEditingExistingRecord ? "Update" : "Save") { Task { await model.save() } }.disabled(!model.canSave)
                        }
                    }
                }
                .disabled(model.phase == .saving)
                .interactiveDismissDisabled(model.phase == .saving)
                .task { await model.loadRetailers() }
                .task { if !model.isEditingExistingRecord { await model.suggestMetadataIfNeeded() } }
                .onChange(of: model.retailer) { model.retailerTextChanged() }
                .sheet(isPresented: $showingRetailers, onDismiss: { Task { await model.loadRetailers() } }) {
                    RetailerBrowserView { saved, policies in
                        model.applyRetailerChoice(saved, selectedPolicies: policies)
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
            Label(model.isEditingExistingRecord ? "Receipt updated" : "Receipt saved", systemImage: "checkmark.circle")
        } description: {
            VStack(spacing: 6) {
                Text(model.isEditingExistingRecord ? "Your changes have been saved." : "Find it in the Receipts tab.")
                if model.hasActiveRemindersSet && !model.notificationsAllowed {
                    Text("Reminders saved, but notifications are off in iOS Settings.")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
            }
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
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondary)
                    }
                }
                .foregroundStyle(Color.primary)
                TextField("Retailer", text: $model.retailer).textInputAutocapitalization(.words)
                DatePicker("Purchase date", selection: $model.date, in: ...Date.now, displayedComponents: .date)
                Picker("Profile", selection: $model.profile) {
                    ForEach(PurchaseProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }

            if let name = model.selectedRetailerName {
                Section {
                    Label("Policies from \(name). Select which ones apply to this receipt.", systemImage: "storefront")
                        .font(.footnote)
                }
            }

            // Legal liability protection notice placed directly above policy sections
            Section { PolicyLiabilityNotice() }

            PolicySections(drafts: $model.policyDrafts, showsApplies: true, purchaseDate: model.date)

            if model.selectedRetailerID == nil {
                Section { Toggle("Remember this retailer and its policies", isOn: $model.rememberRetailer) }
            }

            Section("Amount") {
                Picker("Currency", selection: $model.currency) {
                    ForEach(model.currencies, id: \.self) { Text($0).tag($0) }
                }
                TextField("Total", text: $model.totalText).keyboardType(.decimalPad)
            }

            Section("Category and tags") {
                TextField("Category", text: $model.category).textInputAutocapitalization(.words)
                TextField("Tags, separated by commas", text: $model.tagsText).textInputAutocapitalization(.words)
                if model.isSuggestingMetadata {
                    Label("Suggesting metadata on device…", systemImage: "sparkles")
                } else if let message = model.metadataSuggestionMessage {
                    Text(message).font(.footnote).foregroundStyle(Color.secondary)
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
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.red) }
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
