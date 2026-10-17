//
//  ReturnRemindersView.swift
//  Folio
//
//  Created by Brandon Hua on 17/10/2026.
//

import SwiftUI

/// One row in the reminders list: retailer, deadline and status.
struct ReminderRowView: View {
    let summary: ReminderSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Retailer name as the main line
                Text(summary.retailerName)
                    .font(.headline)

                // Deadline date underneath, in smaller grey text
                Text("Return by \(summary.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status badge on the right, e.g. "2 days left" in amber
            Text(summary.status.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(summary.status.colour)
        }
        .padding(.vertical, 4)
        // VoiceOver reads the whole row as one item instead of three separate pieces
        .accessibilityElement(children: .combine)
    }
}

// How each status is shown. Kept here because it's display-only, not business logic.
extension ReturnReminderStatus {
    var label: String {
        switch self {
        case .upcoming(let days): 
            return "\(days) days left"
        case .dueSoon(let days):  
            if days == 0 { return "Due today" }
            return days == 1 ? "1 day left" : "\(days) days left"
        case .expired:
            return "Expired"
        }
    }

    var colour: Color {
        switch self {
        case .upcoming: return .secondary
        case .dueSoon:  return .orange   // stand-in for WarningAmber
        case .expired:  return .red   // stand-in for ErrorRed
        }
    }
}

/// The return reminders screen. Shows a spinner, an empty message, an error, or the list.
struct ReturnRemindersView: View {
    @State var viewModel: ReturnRemindersViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading reminders…")

            case .empty:
                ContentUnavailableView(
                    "No return reminders",
                    systemImage: "bell.slash",
                    description: Text("Save a receipt with a return policy, then set a reminder so you don't miss the deadline.")
                )

            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load reminders", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") {
                        Task { await viewModel.load() }
                    }
                }

            case .loaded(let summaries):
                List(summaries) { summary in
                    ReminderRowView(summary: summary)
                }
            }
        }
        .navigationTitle("Returns")
        .task { await viewModel.load() }   // load when the screen first appears
    }
}

#if DEBUG
// MARK: - Preview with sample data (never included in the release app)

@MainActor private final class PreviewReceiptRepository: ReceiptRepository {
    var receipts: [PurchaseReceipt]
    init(receipts: [PurchaseReceipt]) { self.receipts = receipts }
    func save(_ receipt: PurchaseReceipt) async throws { receipts.append(receipt) }
    func fetchAll() async throws -> [PurchaseReceipt] { receipts }
}

@MainActor private final class PreviewReminderRepository: ReminderRepository {
    var reminders: [ReturnReminder]
    init(reminders: [ReturnReminder]) { self.reminders = reminders }
    func save(_ reminder: ReturnReminder) async throws { reminders.append(reminder) }
    func fetchAll() async throws -> [ReturnReminder] { reminders }
}

#Preview("Reminders") {
    let day: TimeInterval = 24 * 60 * 60
    let now = Date()

    // Three sample receipts from different stores
    let jbHiFi = PurchaseReceipt(retailer: Retailer(name: "JB Hi-Fi"), purchasedAt: now.addingTimeInterval(-12 * day),
                                 currencyCode: "AUD", total: 199)
    let kmart = PurchaseReceipt(retailer: Retailer(name: "Kmart"), purchasedAt: now.addingTimeInterval(-10 * day),
                                currencyCode: "AUD", total: 45)
    let myer = PurchaseReceipt(retailer: Retailer(name: "Myer"), purchasedAt: now.addingTimeInterval(-31 * day),
                               currencyCode: "AUD", total: 120)

    // One reminder in each status: due soon, upcoming and expired
    let reminders = [
        ReturnReminder(receiptID: jbHiFi.id, deadline: now.addingTimeInterval(2 * day), notifyAt: now),
        ReturnReminder(receiptID: kmart.id, deadline: now.addingTimeInterval(20 * day), notifyAt: now),
        ReturnReminder(receiptID: myer.id, deadline: now.addingTimeInterval(-1 * day), notifyAt: now),
    ]

    let loadSummaries = LoadReminderSummaries(
        reminders: PreviewReminderRepository(reminders: reminders),
        receipts: PreviewReceiptRepository(receipts: [jbHiFi, kmart, myer])
    )

    return NavigationStack {
        ReturnRemindersView(viewModel: ReturnRemindersViewModel(loadReminderSummaries: loadSummaries))
    }
}
#endif
