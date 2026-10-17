import SwiftUI

@MainActor @Observable final class AppViewModel {
    private(set) var dependencies: DependencyContainer?
    private(set) var errorMessage: String?

    func load() {
        guard dependencies == nil else { return }
        do {
            dependencies = try DependencyContainer.live()
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
            } else {
                // Temporary scanner integration for testing camera and extraction flow
                ReceiptScannerView()
            }
        }
        .task { model.load() }
    }
}
