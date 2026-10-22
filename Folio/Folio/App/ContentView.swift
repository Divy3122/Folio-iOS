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
        NavigationStack {
            Group {
                if let message = model.errorMessage {
                    ContentUnavailableView {
                        Label(
                            "Local storage unavailable",
                            systemImage: "externaldrive.badge.exclamationmark"
                        )
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again", action: model.load)
                    }
                } else if let dependencies = model.dependencies {
                    SpendingDashboardView(container: dependencies)
                } else {
                    ProgressView("Preparing Folio...")
                }
            }
            .navigationTitle("Folio")
        }
        .task { model.load() }
    }
}

#Preview {
    ContentView()
}
