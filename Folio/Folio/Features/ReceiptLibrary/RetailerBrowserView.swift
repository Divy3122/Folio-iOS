import SwiftUI
import Observation

extension SavedRetailer {
    var defaultReturnPolicyID: UUID? {
        policies.filter { $0.kind == .returns }.min { $0.windowDays < $1.windowDays }?.id
    }

    var defaultWarrantyMonths: Int {
        policies.first { $0.kind == .warranty }.map { WarrantyLength.months(days: $0.windowDays) } ?? 0
    }
}

enum WarrantyLength {
    static let maxMonths = 120

    static func days(months: Int) -> Int {
        min(3650, Int((Double(months) * 365.25 / 12).rounded()))
    }

    static func months(days: Int) -> Int {
        guard days > 0 else { return 0 }
        return min(maxMonths, max(1, Int((Double(days) / 30.4375).rounded())))
    }

    static func describe(months: Int) -> String {
        guard months > 0 else { return "None" }
        let years = months / 12
        let rest = months % 12
        var parts: [String] = []
        if years > 0 { parts.append(years == 1 ? "1 year" : "\(years) years") }
        if rest > 0 { parts.append(rest == 1 ? "1 month" : "\(rest) months") }
        return parts.joined(separator: " ")
    }
}

@MainActor @Observable
final class RetailerBrowserViewModel {
    struct LetterGroup: Identifiable {
        let letter: String
        let retailers: [SavedRetailer]
        var id: String { letter }
    }

    private(set) var retailers: [SavedRetailer] = []
    private(set) var hasLoaded = false
    var searchText = ""
    var errorMessage: String?

    var groups: [LetterGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? retailers : retailers.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let grouped = Dictionary(grouping: filtered) { Self.letter(for: $0.name) }
        let letters = grouped.keys.sorted { lhs, rhs in
            if lhs == "#" { return false }
            if rhs == "#" { return true }
            return lhs < rhs
        }
        return letters.map { LetterGroup(letter: $0, retailers: grouped[$0] ?? []) }
    }

    private var manage: ManageRetailers? { ReceiptSavingContext.current?.services.manageRetailers }

    func retailer(id: UUID) -> SavedRetailer? { retailers.first { $0.id == id } }

    func load() async {
        guard let manage else {
            errorMessage = "Retailer storage isn't available."
            return
        }
        do {
            retailers = try await manage.all()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ retailer: SavedRetailer) async throws {
        guard let manage else { throw FolioError.persistenceFailure }
        try await manage.save(retailer)
        retailers = try await manage.all()
    }

    func delete(id: UUID) async throws {
        guard let manage else { throw FolioError.persistenceFailure }
        try await manage.delete(id: id)
        retailers = try await manage.all()
    }

    private static func letter(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

struct RetailerBrowserView: View {
    typealias Choose = (SavedRetailer, UUID?, Int) -> Void

    @State private var model = RetailerBrowserViewModel()
    @State private var showingNewRetailer = false
    @Environment(\.dismiss) private var dismiss
    private let onChoose: Choose

    init(onChoose: @escaping Choose) {
        self.onChoose = onChoose
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.groups) { group in
                    Section(group.letter) {
                        ForEach(group.retailers) { retailer in
                            NavigationLink(value: retailer.id) {
                                RetailerRow(retailer: retailer)
                            }
                        }
                    }
                }
            }
            .overlay { emptyState }
            .navigationTitle("Retailers")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, prompt: "Search retailers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add retailer", systemImage: "plus") { showingNewRetailer = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                RetailerDetailView(retailerID: id, model: model, onChoose: onChoose, finish: { dismiss() })
            }
            .sheet(isPresented: $showingNewRetailer) {
                NewRetailerView(model: model)
            }
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
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RetailerAvatar: View {
    let name: String
    var size: CGFloat = 40

    private var initial: String {
        guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(.tint))
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
    @State private var returnPolicyID: UUID?
    @State private var warrantyMonths = 0
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var didLoad = false
    @Environment(\.dismiss) private var dismiss

    private var retailer: SavedRetailer? { model.retailer(id: retailerID) }

    var body: some View {
        Group {
            if let retailer {
                content(for: retailer)
            } else {
                ContentUnavailableView("Retailer not found", systemImage: "storefront")
            }
        }
        .navigationTitle(isEditing ? "Edit retailer" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                        errorMessage = nil
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Done") {
                        if let retailer { Task { await saveEdits(retailer) } }
                    }
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
        .onAppear { loadDefaultsIfNeeded() }
    }

    private func content(for retailer: SavedRetailer) -> some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        RetailerAvatar(name: retailer.name, size: 88)
                        Text(retailer.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            if isEditing {
                RetailerEditForm(name: $name, policies: $drafts)
                Section {
                    Button("Delete retailer", role: .destructive) { confirmDelete = true }
                }
            } else {
                returnPolicySection(for: retailer)
                warrantySection
                Section { PolicyLiabilityNotice() }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !isEditing {
                Button {
                    onChoose(retailer, returnPolicyID, warrantyMonths)
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

    private func returnPolicySection(for retailer: SavedRetailer) -> some View {
        let returns = retailer.policies.filter { $0.kind == .returns }
        return Section("Return policy") {
            if returns.isEmpty {
                Text("No return policies saved. Choose Edit to add one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(returns) { policy in
                Button {
                    returnPolicyID = policy.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.title).foregroundStyle(.primary)
                            Text(detail(for: policy)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if returnPolicyID == policy.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(returnPolicyID == policy.id ? .isSelected : [])
            }
            if !returns.isEmpty {
                Button {
                    returnPolicyID = nil
                } label: {
                    HStack {
                        Text("No return policy for this receipt").foregroundStyle(.primary)
                        Spacer()
                        if returnPolicyID == nil {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(returnPolicyID == nil ? .isSelected : [])
            }
        }
    }

    private var warrantySection: some View {
        Section {
            Stepper(value: $warrantyMonths, in: 0...WarrantyLength.maxMonths) {
                LabeledContent("Warranty length", value: WarrantyLength.describe(months: warrantyMonths))
            }
        } header: {
            Text("Warranty")
        } footer: {
            Text("Set how long the warranty lasts for this receipt. It starts on the purchase date.")
        }
    }

    private func detail(for policy: SavedPolicy) -> String {
        let days = "\(policy.windowDays) days"
        return policy.notes.isEmpty ? days : "\(days) · \(policy.notes)"
    }

    private func loadDefaultsIfNeeded() {
        guard !didLoad, let retailer else { return }
        didLoad = true
        returnPolicyID = retailer.defaultReturnPolicyID
        warrantyMonths = retailer.defaultWarrantyMonths
    }

    private func beginEditing(_ retailer: SavedRetailer) {
        name = retailer.name
        drafts = retailer.policies.map(PolicyDraft.init)
        errorMessage = nil
        isEditing = true
    }

    private func saveEdits(_ retailer: SavedRetailer) async {
        guard drafts.allSatisfy(\.isValid) else {
            errorMessage = RetailerError.invalidPolicy.localizedDescription
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
                returnPolicyID = fresh.defaultReturnPolicyID
                warrantyMonths = fresh.defaultWarrantyMonths
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

    var body: some View {
        NavigationStack {
            List {
                RetailerEditForm(name: $name, policies: $drafts)
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New retailer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .disabled(isSaving)
        }
    }

    private func save() async {
        guard drafts.allSatisfy(\.isValid) else {
            errorMessage = RetailerError.invalidPolicy.localizedDescription
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


struct RetailerEditForm: View {
    @Binding var name: String
    @Binding var policies: [PolicyDraft]

    var body: some View {
        Section("Retailer") {
            TextField("Retailer name", text: $name)
                .textInputAutocapitalization(.words)
        }

        Section {
            ForEach($policies) { $draft in
                if draft.kind == .returns {
                    PolicyEditor(
                        draft: $draft,
                        showsApplies: false,
                        fixedKind: .returns
                    ) {
                        policies.removeAll { $0.id == draft.id }
                    }
                }
            }

            Button {
                addPolicy(.returns)
            } label: {
                Label("Add return policy", systemImage: "plus.circle")
            }
        } header: {
            Text("Return policies")
        } footer: {
            Text("Set the return window in days. Add separate policies for change of mind, faulty items, or other conditions.")
        }

        Section {
            ForEach($policies) { $draft in
                if draft.kind == .warranty {
                    PolicyEditor(
                        draft: $draft,
                        showsApplies: false,
                        fixedKind: .warranty
                    ) {
                        policies.removeAll { $0.id == draft.id }
                    }
                }
            }

            Button {
                addPolicy(.warranty)
            } label: {
                Label("Add warranty", systemImage: "plus.circle")
            }

            PolicyLiabilityNotice()
        } header: {
            Text("Warranties")
        } footer: {
            Text("Warranty durations can be entered in days, months, or years. They are stored as days.")
        }
    }

    private func addPolicy(_ kind: SavedPolicy.Kind) {
        var draft = PolicyDraft()
        draft.kind = kind
        draft.title = kind == .returns ? "Return policy" : "Warranty"
        draft.daysText = kind == .returns ? "30" : ""
        draft.warrantyValue = 12
        draft.warrantyUnit = .months
        policies.append(draft)
    }
}



struct PolicyEditor: View {
    @Binding var draft: PolicyDraft
    var showsApplies = true
    var fixedKind: SavedPolicy.Kind? = nil
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let fixedKind {
                Label(
                    fixedKind == .returns ? "Return policy" : "Warranty",
                    systemImage: fixedKind == .returns
                        ? "arrow.uturn.backward.circle"
                        : "checkmark.shield"
                )
                .font(.headline)
            } else {
                Picker("Type", selection: $draft.kind) {
                    ForEach(SavedPolicy.Kind.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }

            TextField(
                fixedKind == .warranty ? "Warranty name" : "Policy name",
                text: $draft.title
            )
            .textInputAutocapitalization(.words)

            if effectiveKind == .returns {
                returnDurationPicker
            } else {
                warrantyDurationPicker
            }

            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                .lineLimit(2...4)

            if showsApplies {
                Toggle("Applies to this receipt", isOn: $draft.applies)
            }

            Button("Remove policy", role: .destructive, action: onRemove)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .onChange(of: draft.kind) { _, newKind in
            if newKind == .warranty {
                draft.warrantyUnit = .days
                draft.warrantyValue = min(
                    3650,
                    max(1, Int(draft.daysText) ?? 30)
                )
            }
        }
    }

    private var effectiveKind: SavedPolicy.Kind {
        fixedKind ?? draft.kind
    }

    private var returnDurationPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Return window")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Return window in days", selection: returnDaysBinding) {
                ForEach(1...3650, id: \.self) { day in
                    Text("\(day) \(day == 1 ? "day" : "days")")
                        .tag(day)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 120)
            .clipped()
            .accessibilityLabel("Return window in days")
        }
    }

    private var returnDaysBinding: Binding<Int> {
        Binding(
            get: {
                min(3650, max(1, Int(draft.daysText) ?? 30))
            },
            set: {
                draft.daysText = String($0)
            }
        )
    }

    private var warrantyDurationPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Warranty duration")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Picker("Duration", selection: $draft.warrantyValue) {
                    ForEach(
                        1...draft.warrantyUnit.maximum,
                        id: \.self
                    ) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()

                Picker("Unit", selection: $draft.warrantyUnit) {
                    ForEach(PolicyDraft.WarrantyUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 120)
            .onChange(of: draft.warrantyUnit) { _, unit in
                draft.warrantyValue = min(
                    unit.maximum,
                    max(1, draft.warrantyValue)
                )
            }

            if let days = draft.days {
                Text("Stored as \(days) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


struct PolicyLiabilityNotice: View {
    var body: some View {
        Label {
            Text("You are responsible for entering accurate return and warranty policies. Folio can't verify them, and they are not legal advice or a statement of your consumer rights. Check the retailer's own terms.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.footnote)
    }
}
