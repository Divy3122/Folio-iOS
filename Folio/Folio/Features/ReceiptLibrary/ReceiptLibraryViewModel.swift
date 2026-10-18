import Foundation
import Observation

@MainActor @Observable final class ReceiptLibraryViewModel {
    enum State: Equatable { case loading, loaded, failed(String) }

    struct Query: Equatable {
        var searchText: String
        var profile: PurchaseProfile?
        var sort: ReceiptFilter.Sort
    }

    private(set) var records: [ReceiptRecord] = []
    private(set) var state: State = .loading

    var searchText = ""
    var profile: PurchaseProfile?
    var sort: ReceiptFilter.Sort = .dateDescending

    private let services: ReceiptLibraryServices
    private var hasLoaded = false
    private var loadedSearchText = ""

    init(services: ReceiptLibraryServices) {
        self.services = services
    }

    var query: Query { Query(searchText: searchText, profile: profile, sort: sort) }

    func reload() async {
        if hasLoaded && searchText != loadedSearchText {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        let text = searchText
        let filter = ReceiptFilter(searchText: text, profile: profile, sort: sort)
        do {
            let result = try await services.searchReceipts(filter)
            guard !Task.isCancelled else { return }
            records = result
            loadedSearchText = text
            hasLoaded = true
            state = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
