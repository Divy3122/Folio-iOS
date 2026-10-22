import SwiftUI

struct ReceiptLibraryView: View {
    @State private var model: ReceiptLibraryViewModel
    private let services: ReceiptLibraryServices
    private let container: DependencyContainer?

    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showReminders = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(services: ReceiptLibraryServices, container: DependencyContainer? = nil) {
        self.services = services
        self.container = container
        _model = State(initialValue: ReceiptLibraryViewModel(services: services))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Receipts")
                .searchable(text: $model.searchText, prompt: "Search retailer, item or tag")
                .toolbar { toolbarContent }
                .navigationDestination(for: ReceiptRecord.self) { record in
                    ReceiptDetailView(record: record, services: services)
                }
                .sheet(isPresented: $showReminders) {
                    if let container {
                        NavigationStack {
                            ReturnRemindersView(viewModel: ReturnRemindersViewModel(
                                loadReminderSummaries: container.loadReminderSummaries,
                                deleteReturnReminder: container.deleteReturnReminder
                            ))
                            .navigationDestination(for: ReminderReceiptLink.self) { link in
                                ReceiptDetailLoader(receiptID: link.receiptID, services: services)
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? "receipt" : "receipts")?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteSelectedReceipts() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This action cannot be undone.")
                }
                .task(id: model.query) { await model.reload() }
                .task { await seedSamplesOnce() }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading receipts")
        case .failed(let message):
            ContentUnavailableView {
                Label("Receipts unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.reload() } }
            }
        case .loaded:
            if model.records.isEmpty { emptyState } else { receiptGrid }
        }
    }

    private var receiptGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.records) { record in
                    if isSelecting {
                        Button {
                            toggleSelection(for: record.id)
                        } label: {
                            ReceiptCubeView(
                                record: record,
                                isSelecting: true,
                                isSelected: selectedIDs.contains(record.id)
                            )
                        }
                        .buttonStyle(CubeButtonStyle())
                    } else {
                        NavigationLink(value: record) {
                            ReceiptCubeView(record: record)
                        }
                        .buttonStyle(CubeButtonStyle())
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            if !isSelecting { await model.reload() }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.profile != nil {
            ContentUnavailableView("No receipts for this profile", systemImage: "tray",
                                   description: Text("Try another profile, or scan a receipt."))
        } else {
            ContentUnavailableView("No receipts yet", systemImage: "receipt",
                                   description: Text("Receipts you scan are stored here and work offline."))
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                // Reminders / Notifications Button
                Button {
                    showReminders = true
                } label: {
                    Label("Reminders", systemImage: "bell")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                }

                // Batch Deletion Trash Button
                Button(role: .destructive) {
                    if isSelecting {
                        if !selectedIDs.isEmpty {
                            showDeleteConfirmation = true
                        } else {
                            withAnimation { isSelecting = false }
                        }
                    } else {
                        withAnimation { isSelecting = true }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .foregroundStyle(selectedIDs.isEmpty && isSelecting ? Color.secondary : Color.red)
                }
                .disabled(model.records.isEmpty || isDeleting)

                // Select / Cancel Mode Toggle
                if isSelecting {
                    Button(selectedIDs.count == model.records.count ? "Deselect All" : "Select All") {
                        if selectedIDs.count == model.records.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(model.records.map(\.id))
                        }
                    }
                    .font(.subheadline.weight(.semibold))

                    Button("Done") {
                        withAnimation {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    }
                    .bold()
                } else {
                    filterMenu
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Profile", selection: $model.profile) {
                Text("All profiles").tag(PurchaseProfile?.none)
                ForEach(PurchaseProfile.allCases, id: \.self) { profile in
                    Text(profile.rawValue.capitalized).tag(PurchaseProfile?.some(profile))
                }
            }
            Picker("Sort by", selection: $model.sort) {
                ForEach(ReceiptFilter.Sort.menuOrder, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            #if DEBUG
            Button("Add sample receipts") {
                Task {
                    _ = try? await ReceiptLibrarySampleData.seed(into: services)
                    await model.reload()
                }
            }
            #endif
        } label: {
            Label("Filter and sort", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSelectedReceipts() async {
        guard !selectedIDs.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }

        for id in selectedIDs {
            try? await services.repository.delete(id: id)
            try? await services.reminders?.delete(id: id)
            try? services.images.delete(receiptID: id)
        }

        selectedIDs.removeAll()
        withAnimation { isSelecting = false }
        await model.reload()
    }

    private func seedSamplesOnce() async {
        #if DEBUG
        let key = "ReceiptLibrarySamplesSeeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        _ = try? await ReceiptLibrarySampleData.seed(into: services)
        UserDefaults.standard.set(true, forKey: key)
        await model.reload()
        #endif
    }
}

// MARK: - Button Style

private struct CubeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Required Protocol Conformance Extensions

extension ReceiptRecord: Hashable {
    static func == (lhs: ReceiptRecord, rhs: ReceiptRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ReceiptFilter.Sort {
    static let menuOrder: [ReceiptFilter.Sort] = [
        .dateDescending, .dateAscending, .totalDescending, .totalAscending, .retailerAscending
    ]

    var title: String {
        switch self {
        case .dateDescending: "Newest first"
        case .dateAscending: "Oldest first"
        case .totalDescending: "Highest total"
        case .totalAscending: "Lowest total"
        case .retailerAscending: "Retailer A–Z"
        }
    }
}
