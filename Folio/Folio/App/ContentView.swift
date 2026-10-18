import SwiftUI

@MainActor @Observable final class AppViewModel {
    private(set) var dependencies: DependencyContainer?
    private(set) var library: ReceiptLibraryServices?
    private(set) var errorMessage: String?

    func load() {
        guard dependencies == nil else { return }
        do {
            let loaded = try DependencyContainer.live()
            let services = try ReceiptLibraryServices(container: loaded)
            ReceiptSavingContext.current = ReceiptSavingContext(services: services, saveReceipt: loaded.saveReceipt)
            library = services
            dependencies = loaded
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ContentView: View {
    @State private var model = AppViewModel()

    var body: some View {
        Group {
            if let message = model.errorMessage {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Local storage unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again", action: model.load)
                    }
                    .navigationTitle("Folio")
                }
            } else if let library = model.library {
                TabView {
                    ReceiptScannerView()
                        .tabItem { Label("Scan", systemImage: "doc.viewfinder") }
                    ReceiptLibraryView(services: library)
                        .tabItem { Label("Receipts", systemImage: "receipt") }
                }
            } else {
                ProgressView()
            }
        }
        .task { model.load() }
    }
}
