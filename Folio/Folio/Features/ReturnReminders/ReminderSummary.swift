//
//  ReminderSummary.swift
//  Folio
//
//  Created by Brandon Hua on 16/10/2026.
//

import Foundation

/// Everything one row of the reminders list needs to display.
struct ReminderSummary: Identifiable, Equatable, Sendable {
    let id: UUID                     // the reminder's id
    let receiptID: UUID
    let retailerName: String
    let deadline: Date
    let notifyAt: Date
    let status: ReturnReminderStatus
}

/// Loads every reminder, pairs it with its receipt, and works out its status.
@MainActor struct LoadReminderSummaries {
    let reminders: any ReminderRepository
    let receipts: any ReceiptRepository
    var determineStatus = DetermineReminderStatus()

    func callAsFunction() async throws -> [ReminderSummary] {
        // 1. Load everything from storage
        let allReminders = try await reminders.fetchAll()
        let allReceipts = try await receipts.fetchAll()

        // 2–3. Turn each reminder into a summary row
        let summaries = allReminders.map { reminder in
            // Find the receipt this reminder belongs to
            let matchingReceipt = allReceipts.first(where: { $0.id == reminder.receiptID })

            return ReminderSummary(
                id: reminder.id,
                receiptID: reminder.receiptID,
                retailerName: matchingReceipt?.retailer.name ?? "Unknown retailer",
                deadline: reminder.deadline,
                notifyAt: reminder.notifyAt,
                status: determineStatus(reminder)
            )
        }

        // 4. Soonest deadline first
        return summaries.sorted { $0.deadline < $1.deadline }
    }
}

/// Deletes a reminder and cancels its notification so it never fires.
@MainActor struct DeleteReturnReminder {
    let reminders: any ReminderRepository
    let scheduler: any ReminderScheduling

    func callAsFunction(id: UUID) async throws {
        // Remove from storage first; if that fails, the notification is left alone
        try await reminders.delete(id: id)
        // Then make sure it never fires
        await scheduler.cancel(id: id)
    }
}
