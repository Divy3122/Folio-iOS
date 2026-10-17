//
//  CreateReminderViewModel.swift
//  Folio
//
//  Created by Brandon Hua on 17/10/2026.
//

import Foundation
import Observation

/// Drives the "Set return reminder" screen for one saved receipt.
@MainActor @Observable final class CreateReminderViewModel {

    /// What happened when the user tapped Save.
    enum SaveOutcome: Equatable {
        case idle
        case saving
        case saved(notificationsEnabled: Bool)   // reminder saved; were notifications allowed?
        case failed(String)                      // message to show the user
    }

    let receipt: PurchaseReceipt

    /// The sample policy picked by the user. Picking one resets the window to that policy's days.
    var selectedPolicy: RetailerPolicyTemplate {
        didSet { windowDays = selectedPolicy.windowDays }
    }
    /// How many days the user has to return the item. Editable, so the user can correct the deadline.
    var windowDays: Int
    /// When the notification should fire.
    var notifyAt: Date

    private(set) var outcome: SaveOutcome = .idle

    private let saveReceipt: SaveReceipt
    private let createReturnReminder: CreateReturnReminder
    private let scheduler: any ReminderScheduling
    private let calendar = Calendar.current

    init(receipt: PurchaseReceipt,
         saveReceipt: SaveReceipt,
         createReturnReminder: CreateReturnReminder,
         scheduler: any ReminderScheduling) {
        self.receipt = receipt
        self.saveReceipt = saveReceipt
        self.createReturnReminder = createReturnReminder
        self.scheduler = scheduler

        // Start with a policy suggested from the retailer's name
        let suggested = SampleReturnPolicies.suggestedPolicy(forRetailer: receipt.retailer.name)
        self.selectedPolicy = suggested
        self.windowDays = suggested.windowDays

        // Placeholder; replaced with a sensible default just below
        self.notifyAt = Date()
        self.notifyAt = defaultReminderDate()
    }

    /// The last day to return, shown live on screen. (CreateReturnReminder does the official calculation on save.)
    var deadline: Date {
        calendar.date(byAdding: .day, value: windowDays, to: receipt.purchasedAt) ?? receipt.purchasedAt
    }

    /// The reminder can be set from now up to the deadline.
    var allowedReminderDates: ClosedRange<Date> {
        let now = Date()
        return now...max(now, deadline)
    }

    /// Default: 9 am the day before the deadline, or soon if that has already passed.
    private func defaultReminderDate() -> Date {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: deadline) ?? deadline
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore) ?? dayBefore
        // If that time is already in the past, remind in 1 minute instead
        return nineAM > Date() ? nineAM : Date().addingTimeInterval(60)
    }

    /// Saves the policy, creates the reminder, then tries to schedule the notification.
    func save() async {
        outcome = .saving
        do {
            // 1. Save the chosen policy onto the receipt
            var updatedReceipt = receipt
            updatedReceipt.returnPolicy = ReturnPolicy(windowDays: windowDays, notes: selectedPolicy.notes)
            try await saveReceipt(updatedReceipt)

            // 2. Create the reminder (the shared use case checks the dates are valid)
            let reminder = try await createReturnReminder(receiptID: receipt.id, notifyAt: notifyAt)

            // 3. Try to schedule the notification. Failure here never undoes the saved reminder.
            let notificationsEnabled = await scheduleNotification(for: reminder)
            outcome = .saved(notificationsEnabled: notificationsEnabled)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }

    /// Asks permission (in context, at the moment it's needed) and schedules. Returns whether it worked.
    private func scheduleNotification(for reminder: ReturnReminder) async -> Bool {
        do {
            guard try await scheduler.requestAuthorization() else { return false }
            try await scheduler.schedule(reminder)
            return true
        } catch {
            return false
        }
    }
}
