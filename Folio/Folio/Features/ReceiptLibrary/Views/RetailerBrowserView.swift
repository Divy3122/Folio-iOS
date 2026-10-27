import SwiftUI
import Observation

struct RetailerBrowserView: View {
    typealias Choose = (SavedRetailer, [SavedPolicy]) -> Void

    @State private var model = RetailerBrowserViewModel()
    @State private var showingNewRetailer = false
    @Environment(\.dismiss) private var dismiss
    private let onChoose: Choose

    init(onChoose: @escaping Choose) { self.onChoose = onChoose }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.groups) { group in
                    Section(group.letter) {
                        ForEach(group.retailers) { retailer in
                            NavigationLink(value: retailer.id) { RetailerRow(retailer: retailer) }
                        }
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Retailers")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, prompt: "Search retailers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add retailer", systemImage: "plus") { showingNewRetailer = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                RetailerDetailView(retailerID: id, model: model, onChoose: onChoose, finish: { dismiss() })
            }
            .sheet(isPresented: $showingNewRetailer) { NewRetailerView(model: model) }
            .alert("Retailers", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .task { await model.load() }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.hasLoaded && model.groups.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView("No saved retailers", systemImage: "storefront",
                                       description: Text("Tap + to add a retailer and its return and warranty policies."))
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

private struct RetailerRow: View {
    let retailer: SavedRetailer

    private var summary: String {
        var parts: [String] = []
        let returns = retailer.policies.filter { $0.kind == .returns }
        if returns.count == 1, let only = returns.first {
            parts.append("Returns \(only.windowDays) days")
        } else if returns.count > 1 {
            parts.append("\(returns.count) return policies")
        }
        if retailer.defaultWarrantyMonths > 0 {
            parts.append("Warranty \(WarrantyLength.describe(months: retailer.defaultWarrantyMonths))")
        }
        return parts.isEmpty ? "No policies yet" : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RetailerAvatar(name: retailer.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(retailer.name).font(.headline)
                Text(summary).font(.caption).foregroundStyle(Color.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RetailerAvatar: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Text(name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor))
            .accessibilityHidden(true)
    }
}

struct RetailerDetailView: View {
    let retailerID: UUID
    let model: RetailerBrowserViewModel
    let onChoose: RetailerBrowserView.Choose
    let finish: () -> Void

    @State private var isEditing = false
    @State private var name = ""
    @State private var drafts: [PolicyDraft] = []
    @State private var selected: Set<UUID> = []
    @State private var didLoad = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var retailer: SavedRetailer? { model.retailer(id: retailerID) }

    private var canSaveEdits: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        drafts.allSatisfy { !$0.isEditing && $0.isValid }
    }

    var body: some View {
        Group {
            if let retailer { content(for: retailer) } else { ContentUnavailableView("Retailer not found", systemImage: "storefront") }
        }
        .navigationTitle(isEditing ? "Edit retailer" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing { Button("Cancel") { isEditing = false; errorMessage = nil } }
            }
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Done") { if let retailer { Task { await saveEdits(retailer) } } }
                        .disabled(!canSaveEdits)
                } else if let retailer {
                    Button("Edit") { beginEditing(retailer) }
                }
            }
        }
        .confirmationDialog("Delete this retailer?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete retailer", role: .destructive) { Task { await deleteRetailer() } }
        } message: {
            Text("Receipts you have already saved keep their own copy of these policies.")
        }
        .onAppear {
            guard !didLoad, let retailer else { return }
            didLoad = true
            if let id = retailer.defaultReturnPolicyID { selected.insert(id) }
        }
    }

    private func content(for retailer: SavedRetailer) -> some View {
        List {
            Section {
                VStack(spacing: 8) {
                    RetailerAvatar(name: retailer.name, size: 88)
                    Text(retailer.name).font(.title2.bold()).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if isEditing {
                RetailerEditForm(name: $name, policies: $drafts)
                Section { Button("Delete retailer", role: .destructive) { confirmDelete = true } }
            } else {
                Section { PolicyLiabilityNotice() }
                choices("Return policies", retailer.policies.filter { $0.kind == .returns })
                choices("Warranties", retailer.policies.filter { $0.kind == .warranty })
            }

            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.red) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !isEditing {
                Button {
                    onChoose(retailer, retailer.policies.filter { selected.contains($0.id) })
                    finish()
                } label: {
                    Label("Use for this receipt", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
        }
    }

    private func choices(_ title: String, _ policies: [SavedPolicy]) -> some View {
        Section {
            if policies.isEmpty { Text("No \(title.lowercased()) saved.").foregroundStyle(Color.secondary) }
            ForEach(policies) { policy in
                let isSelected = selected.contains(policy.id)
                Button {
                    if isSelected { selected.remove(policy.id) } else { selected.insert(policy.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(policy.title).foregroundStyle(Color.primary)
                            Text(PolicyDraft(policy).durationText).font(.subheadline).foregroundStyle(Color.secondary)
                            if !policy.notes.isEmpty { Text(policy.notes).font(.caption).foregroundStyle(Color.secondary) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        } header: {
            Text(title)
        } footer: {
            Text("Select the policies you want saved with this receipt.")
        }
    }

    private func beginEditing(_ retailer: SavedRetailer) {
        name = retailer.name
        drafts = retailer.policies.map(PolicyDraft.init)
        errorMessage = nil
        isEditing = true
    }

    private func saveEdits(_ retailer: SavedRetailer) async {
        guard canSaveEdits else {
            errorMessage = "Save or remove open policy drafts and ensure titles and durations are valid."
            return
        }
        var updated = retailer
        updated.name = name
        updated.policies = drafts.compactMap(\.saved)
        do {
            try await model.save(updated)
            errorMessage = nil
            isEditing = false
            if let fresh = model.retailer(id: retailerID) {
                selected.formIntersection(fresh.policies.map(\.id))
                if selected.isEmpty, let id = fresh.defaultReturnPolicyID { selected.insert(id) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRetailer() async {
        do {
            try await model.delete(id: retailerID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewRetailerView: View {
    let model: RetailerBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var drafts: [PolicyDraft] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        drafts.allSatisfy { !$0.isEditing && $0.isValid }
    }

    var body: some View {
        NavigationStack {
            List {
                RetailerEditForm(name: $name, policies: $drafts)
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.red) }
                }
            }
            .navigationTitle("New retailer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        guard canSave else {
            errorMessage = "Save or remove open policy drafts and ensure titles and durations are valid."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.save(SavedRetailer(name: name, policies: drafts.compactMap(\.saved)))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
