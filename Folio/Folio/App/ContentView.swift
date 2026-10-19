import SwiftUI

@MainActor @Observable final class AppViewModel {
    private(set) var dependencies: DependencyContainer?
    private(set) var library: ReceiptLibraryServices?
    private(set) var errorMessage: String?

    func load() {
        guard dependencies == nil else { return }
        do {
            let loaded = try DependencyContainer.live()
            let services = try ReceiptLibraryServices(container: loaded, scheduler: NotificationReminderScheduler())
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
                        Text("Dashboard integration pending")
                            .navigationTitle("Home")
                    }
                    .tabItem {
                        Label("Home", systemImage: "house")
                    }

                    NavigationStack {
                        if let library = model.library {
                            ReceiptLibraryView(services: library)
                        }
                    }
                    .tabItem {
                        Label("Receipts", systemImage: "receipt")
                    }

                    NavigationStack {
                        ReceiptScannerView()
                    }
                    .tabItem {
                        Label("Scan", systemImage: "camera")
                    }

                    NavigationStack {
                        if let dependencies = model.dependencies {
                            ReturnRemindersView(viewModel: ReturnRemindersViewModel(
                                loadReminderSummaries: LoadReminderSummaries(
                                    reminders: dependencies.reminders,
                                    receipts: dependencies.receipts
                                ),
                                deleteReturnReminder: DeleteReturnReminder(
                                    reminders: dependencies.reminders,
                                    scheduler: NotificationReminderScheduler()
                                )
                            ))
                        }
                    }
                    .tabItem {
                        Label("Reminders", systemImage: "bell")
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
