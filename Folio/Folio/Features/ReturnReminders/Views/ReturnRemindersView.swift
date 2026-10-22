//
//  ReturnRemindersView.swift
//  Folio
//
//  Created by Brandon Hua on 17/10/2026.
//

import SwiftUI

/// One reminder shown as a card, matching the Receipts tab style.
struct ReminderRowView: View {
    let summary: ReminderSummary
    
    var body: some View {
        HStack(spacing: 12) {
            // Store initial in a circle, same component as the Receipts tab
            RetailerAvatar(name: summary.retailerName, size: 40)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.retailerName)
                    .font(.headline)
                    .foregroundStyle(Color.PrimaryText)
                    .lineLimit(1)
                
                Text("Return by \(summary.deadline.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(Color.SecondaryText)
            }
            
            Spacer()
            
            // Status badge: icon + label in a coloured capsule
            Label(summary.status.label, systemImage: summary.status.iconName)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(summary.status.colour)
                .background(summary.status.colour.opacity(0.15), in: Capsule())
        }
        .padding(14)
        .background(Color.CardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
        // VoiceOver reads the whole card as one item
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
    
    // Team colours from Resources/Colors.swift, so Light and Dark Mode are handled
    var colour: Color {
        switch self {
        case .upcoming: return .SuccessGreen
        case .dueSoon:  return .WarningAmber
        case .expired:  return .ErrorRed
        }
    }
    
    // Matches the icons used on the Receipts tab cards
    var iconName: String {
        switch self {
        case .upcoming: return "shield.checkmark.fill"
        case .dueSoon:  return "exclamationmark.triangle.fill"
        case .expired:  return "xmark.octagon.fill"
        }
    }
}

/// Tapping a reminder asks to open this receipt. ContentView decides which screen shows it.
struct ReminderReceiptLink: Hashable {
    let receiptID: UUID
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
                    ZStack {
                        // Invisible link covering the card, so tapping opens the receipt
                        // (hidden so the list doesn't add a grey arrow next to the card)
                        NavigationLink(value: ReminderReceiptLink(receiptID: summary.receiptID)) { EmptyView() }
                            .opacity(0)
                        ReminderRowView(summary: summary)
                    }
                    // Hide the default row look so only the card shows
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    // Swipe left on a card to delete it
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task { await viewModel.delete(id: summary.id) }
                            }
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Returns")
        // Reload every time the screen appears, including when coming back from a receipt
        .onAppear { Task { await viewModel.load() } }
    }
}

#if DEBUG
// MARK: - Preview with sample data (never included in the release app)

@MainActor private final class PreviewReceiptRepository: ReceiptRepository {
    var receipts: [PurchaseReceipt]
    init(receipts: [PurchaseReceipt]) { self.receipts = receipts }
    func save(_ receipt: PurchaseReceipt) async throws { receipts.append(receipt) }
    func update(_ receipt: PurchaseReceipt) async throws {
    }
    func fetchAll() async throws -> [PurchaseReceipt] { receipts }
}

@MainActor private final class PreviewReminderRepository: ReminderRepository {
    var reminders: [ReturnReminder]
    init(reminders: [ReturnReminder]) { self.reminders = reminders }
    func save(_ reminder: ReturnReminder) async throws { reminders.append(reminder) }
    func fetchAll() async throws -> [ReturnReminder] { reminders }
    func delete(id: UUID) async throws { reminders.removeAll { $0.id == id } }
}

/// Pretends notifications work, without touching the real system.
@MainActor private final class PreviewScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func schedule(_ reminder: ReturnReminder) async throws {}
    func cancel(id: UUID) async {}
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
    
    // One shared store, so deleting a reminder is reflected when the list reloads
    let reminderStore = PreviewReminderRepository(reminders: reminders)
    
    let loadSummaries = LoadReminderSummaries(
        reminders: reminderStore,
        receipts: PreviewReceiptRepository(receipts: [jbHiFi, kmart, myer])
    )
    let deleteReminder = DeleteReturnReminder(reminders: reminderStore, scheduler: PreviewScheduler())
    
    NavigationStack {
        ReturnRemindersView(viewModel: ReturnRemindersViewModel(
            loadReminderSummaries: loadSummaries,
            deleteReturnReminder: deleteReminder
        ))
    }
}
#endif
