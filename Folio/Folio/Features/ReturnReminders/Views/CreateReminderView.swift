//
//  CreateReminderView.swift
//  Folio
//
//  Created by Brandon Hua on 17/10/2026.
//

import SwiftUI
import UIKit   // needed for the "Open Settings" link

/// The "Set return reminder" form for one saved receipt.
struct CreateReminderView: View {
    @State var viewModel: CreateReminderViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            // What was bought, so the user knows which receipt this is
            Section("Purchase") {
                LabeledContent("Retailer", value: viewModel.receipt.retailer.name)
                LabeledContent("Purchased",
                               value: viewModel.receipt.purchasedAt.formatted(date: .abbreviated, time: .omitted))
            }

            // Pick a sample policy, then adjust the number of days if needed
            Section {
                Picker("Policy", selection: $viewModel.selectedPolicy) {
                    ForEach(SampleReturnPolicies.all) { policy in
                        Text(policy.retailerName).tag(policy)
                    }
                }
                Stepper("Return window: \(viewModel.windowDays) days",
                        value: $viewModel.windowDays, in: 1...365)
                Text(viewModel.selectedPolicy.notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Return policy")
            } footer: {
                Text("Sample policies only. Always check the retailer's own policy.")
            }

            // The deadline updates live as the policy or days change
            Section("Deadline") {
                LabeledContent("Return by",
                               value: viewModel.deadline.formatted(date: .complete, time: .omitted))
                if viewModel.deadline < Date() {
                    Label("This return window has already ended.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            // When to be reminded; can't be in the past or after the deadline
            Section("Reminder") {
                DatePicker("Remind me",
                           selection: $viewModel.notifyAt,
                           in: viewModel.allowedReminderDates)
            }

            // Result of tapping Save
            outcomeSection
        }
        .navigationTitle("Set Return Reminder")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await viewModel.save() }
                }
                // Can't save while saving, or when the deadline has already passed
                .disabled(viewModel.outcome == .saving || viewModel.deadline < Date())
            }
        }
    }

    /// Shows success, the "notifications off" notice, or an error after saving.
    @ViewBuilder private var outcomeSection: some View {
        switch viewModel.outcome {
        case .idle:
            EmptyView()

        case .saving:
            Section { ProgressView("Saving…") }

        case .saved(notificationsEnabled: true):
            Section {
                Label("Reminder set. We'll notify you before the deadline.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

        case .saved(notificationsEnabled: false):
            Section {
                Label("Reminder saved, but notifications are off, so you won't be alerted.",
                      systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Button("Turn on notifications in Settings") {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        openURL(settingsURL)
                    }
                }
            }

        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

#if DEBUG
// MARK: - Preview with sample data (never included in the release app)

@MainActor private final class PreviewReceiptStore: ReceiptRepository {
    var receipts: [PurchaseReceipt]
    init(receipts: [PurchaseReceipt]) { self.receipts = receipts }
    // Replace an existing receipt with the same id, like the real repository does
    func save(_ receipt: PurchaseReceipt) async throws {
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
    }
    func fetchAll() async throws -> [PurchaseReceipt] { receipts }
}

@MainActor private final class PreviewReminderStore: ReminderRepository {
    var reminders: [ReturnReminder] = []
    func save(_ reminder: ReturnReminder) async throws { reminders.append(reminder) }
    func fetchAll() async throws -> [ReturnReminder] { reminders }
    func delete(id: UUID) async throws { reminders.removeAll { $0.id == id } }
}

/// Pretends the user allowed notifications, without touching the real system.
@MainActor private final class PreviewScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func schedule(_ reminder: ReturnReminder) async throws {}
    func cancel(id: UUID) async {}
}

#Preview("Set reminder") {
    let receipt = PurchaseReceipt(retailer: Retailer(name: "JB HI-FI BROADWAY"),
                                  purchasedAt: Date().addingTimeInterval(-3 * 24 * 60 * 60),
                                  currencyCode: "AUD", total: 199)
    let receipts = PreviewReceiptStore(receipts: [receipt])
    let reminders = PreviewReminderStore()

    let viewModel = CreateReminderViewModel(
        receipt: receipt,
        saveReceipt: SaveReceipt(repository: receipts),
        createReturnReminder: CreateReturnReminder(receipts: receipts, reminders: reminders),
        scheduler: PreviewScheduler()
    )

    return NavigationStack {
        CreateReminderView(viewModel: viewModel)
    }
}
#endif
