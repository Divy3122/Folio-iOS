import SwiftUI
import UserNotifications

@MainActor @Observable final class AppViewModel {
    private(set) var dependencies: DependencyContainer?
    private(set) var library: ReceiptLibraryServices?
    private(set) var errorMessage: String?

    func load() {
        guard dependencies == nil else { return }
        
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        
        do {
            let loaded = try DependencyContainer.live()
            let services = try ReceiptLibraryServices(container: loaded, scheduler: loaded.scheduler)
            
            ReceiptSavingContext.current = ReceiptSavingContext(
                services: services,
                saveReceipt: loaded.saveReceipt
            )
            
            library = services
            dependencies = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @State private var model = AppViewModel()

    var body: some View {
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
            } else if model.dependencies != nil {
                TabView {
                    NavigationStack {
                        ReceiptScannerView()
                    }
                    .tabItem {
                        Label("Scan", systemImage: "camera")
                    }

                    NavigationStack {
                        if let library = model.library, let dependencies = model.dependencies {
                            ReceiptLibraryView(services: library, container: dependencies)
                        }
                    }
                    .tabItem {
                        Label("Receipts", systemImage: "receipt")
                    }

                    NavigationStack {
                        if let dependencies = model.dependencies {
                            SpendingDashboardView(container: dependencies)
                        }
                    }
                    .tabItem {
                        Label("Insights", systemImage: "chart.bar.fill")
                    }
                }
                .tint(.BrandTeal)
            } else {
                ProgressView("Opening Folio…")
            }
        }
        .task { model.load() }
    }
}

#Preview {
    ContentView()
}
