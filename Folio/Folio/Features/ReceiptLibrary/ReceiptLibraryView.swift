import SwiftUI

struct ReceiptLibraryView: View {
    @State private var model: ReceiptLibraryViewModel
    private let services: ReceiptLibraryServices

    init(services: ReceiptLibraryServices) {
        self.services = services
        _model = State(initialValue: ReceiptLibraryViewModel(services: services))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Receipts")
                .searchable(text: $model.searchText, prompt: "Search retailer, item or tag")
                .toolbar { filterMenu }
                .navigationDestination(for: ReceiptRecord.self) { record in
                    ReceiptDetailView(record: record, services: services)
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
            if model.records.isEmpty { emptyState } else { receiptList }
        }
    }

    private var receiptList: some View {
        List(model.records) { record in
            NavigationLink(value: record) {
                ReceiptRowView(record: record)
            }
        }
        .refreshable { await model.reload() }
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

    @ToolbarContentBuilder private var filterMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
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

extension ReceiptRecord: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
