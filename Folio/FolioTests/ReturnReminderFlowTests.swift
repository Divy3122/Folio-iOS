//
//  ReturnReminderFlowTests.swift
//  FolioTests
//
//  Created by Brandon Hua on 17/10/2026.
//

import Foundation
import Testing
@testable import Folio

// MARK: - Test doubles (fake repositories and scheduler)

@MainActor private final class FakeReceiptRepository: ReceiptRepository {
    func update(_ receipt: Folio.PurchaseReceipt) async throws {

    }
    
    var receipts: [PurchaseReceipt] = []
    func save(_ receipt: PurchaseReceipt) async throws {
        receipts.removeAll { $0.id == receipt.id }   // replace by id, like the real repository
        receipts.append(receipt)
    }
    func fetchAll() async throws -> [PurchaseReceipt] { receipts }
}

@MainActor private final class FakeReminderRepository: ReminderRepository {
    var reminders: [ReturnReminder] = []
    func save(_ reminder: ReturnReminder) async throws { reminders.append(reminder) }
    func fetchAll() async throws -> [ReturnReminder] { reminders }
    func delete(id: UUID) async throws { reminders.removeAll { $0.id == id } }
}

@MainActor private final class FakeScheduler: ReminderScheduling {
    var allowNotifications = true
    var scheduled: [ReturnReminder] = []
    func requestAuthorization() async throws -> Bool { allowNotifications }
    func schedule(_ reminder: ReturnReminder) async throws { scheduled.append(reminder) }
    func cancel(id: UUID) async {}
}

@MainActor struct ReturnReminderFlowTests {

    // MARK: Policy suggestion

    // Receipt names from OCR are often upper case with extra words like the branch name
    @Test func suggestionIgnoresCaseAndExtraWords() {
        let policy = SampleReturnPolicies.suggestedPolicy(forRetailer: "JB HI-FI BROADWAY")
        #expect(policy.retailerName == "JB Hi-Fi")
    }

    // A store that isn't in the sample list should get the generic default
    @Test func unknownRetailerFallsBackToOther() {
        let policy = SampleReturnPolicies.suggestedPolicy(forRetailer: "Corner Bakery Newtown")
        #expect(policy == SampleReturnPolicies.fallback)
    }

    // MARK: Saving a reminder

    /// Builds a view model for a receipt bought 3 days ago, with fakes we can inspect afterwards.
    private func makeViewModel(allowNotifications: Bool)
        -> (CreateReminderViewModel, FakeReminderRepository, FakeScheduler) {
        let receipts = FakeReceiptRepository()
        let reminders = FakeReminderRepository()
        let scheduler = FakeScheduler()
        scheduler.allowNotifications = allowNotifications

        let receipt = PurchaseReceipt(retailer: Retailer(name: "Kmart"),
                                      purchasedAt: Date().addingTimeInterval(-3 * 24 * 60 * 60),
                                      currencyCode: "AUD", total: 45)
        receipts.receipts = [receipt]

        let viewModel = CreateReminderViewModel(
            receipt: receipt,
            saveReceipt: SaveReceipt(repository: receipts),
            createReturnReminder: CreateReturnReminder(receipts: receipts, reminders: reminders),
            scheduler: scheduler
        )
        return (viewModel, reminders, scheduler)
    }

    // Happy path: reminder saved and notification scheduled
    @Test func savingWithNotificationsAllowedSchedulesIt() async {
        let (viewModel, reminders, scheduler) = makeViewModel(allowNotifications: true)
        await viewModel.save()

        #expect(viewModel.outcome == .saved(notificationsEnabled: true))
        #expect(reminders.reminders.count == 1)
        #expect(scheduler.scheduled.count == 1)
    }

    // Architecture rule: notification denial must not delete a saved reminder
    @Test func deniedNotificationsStillSaveTheReminder() async {
        let (viewModel, reminders, scheduler) = makeViewModel(allowNotifications: false)
        await viewModel.save()

        #expect(viewModel.outcome == .saved(notificationsEnabled: false))
        #expect(reminders.reminders.count == 1)   // still saved!
        #expect(scheduler.scheduled.count == 0)   // but nothing scheduled
    }
    
    // A policy chosen when the receipt was saved must not be replaced by the sample suggestion
    @Test func existingReceiptPolicyIsKept() {
        var receipt = PurchaseReceipt(retailer: Retailer(name: "JB Hi-Fi"), purchasedAt: Date(),
                                      currencyCode: "AUD", total: 349)
        receipt.returnPolicy = ReturnPolicy(windowDays: 30, notes: "Chosen on save")
        let receipts = FakeReceiptRepository()
        receipts.receipts = [receipt]

        let viewModel = CreateReminderViewModel(
            receipt: receipt,
            saveReceipt: SaveReceipt(repository: receipts),
            createReturnReminder: CreateReturnReminder(receipts: receipts, reminders: FakeReminderRepository()),
            scheduler: FakeScheduler()
        )
        #expect(viewModel.windowDays == 30)   // not the JB Hi-Fi sample's 14
    }
}
