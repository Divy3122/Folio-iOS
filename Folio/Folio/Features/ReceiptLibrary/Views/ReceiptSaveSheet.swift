import SwiftUI
import Observation

struct ReceiptSaveSheet: View {
    @State private var model: ReceiptSaveViewModel
    @State private var showingRetailers = false
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    init(costs: ReceiptCostBreakdown,
         pages: [Data],
         source: ReceiptMetadata.ExtractionSource? = nil,
         existingRecord: ReceiptRecord? = nil,
         onSaved: @escaping () -> Void = {}) {
        _model = State(initialValue: ReceiptSaveViewModel(costs: costs, pages: pages, source: source, existingRecord: existingRecord))
        self.onSaved = onSaved
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
            
            if model.selectedRetailerID == nil {
                Section {
                    Toggle("Remember this retailer and its policies", isOn: $model.rememberRetailer)
                }
            }

            if let name = model.selectedRetailerName {
                Section {
                    Label("Policies from \(name). Select which ones apply to this receipt.", systemImage: "storefront")
                        .font(.footnote)
                }
            }

            Section { PolicyLiabilityNotice() }

            PolicySections(drafts: $model.policyDrafts, showsApplies: true, purchaseDate: model.date)

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
                    Button("Close without scan details") {
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
    }
}
