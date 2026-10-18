//
//  ReminderStatusTests.swift
//  FolioTests
//
//  Created by Brandon Hua on 16/10/2026.
//

import Foundation
import Testing
@testable import Folio

@MainActor
struct ReminderStatusTests {
    // A fixed "today" and calendar so tests give the same result on any machine
    private let today = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    
    // Builds a reminder whose deadline is a given number of days from "today"
    private func reminder(deadlineInDays days: Int) -> ReturnReminder {
        let deadline = calendar.date(byAdding: .day, value: days, to: today)!
        return ReturnReminder(receiptID: UUID(), deadline: deadline, notifyAt: today)
    }

    // The use case, pretending it's always "today"
    private var determineStatus: DetermineReminderStatus {
        DetermineReminderStatus(calendar: calendar, now: { today })
    }

    @Test func deadlineYesterdayIsExpired() {
        #expect(determineStatus(reminder(deadlineInDays: -1)) == .expired)
    }
    
    // 1. On the deadline day itself, the item is still returnable
    @Test func deadlineTodayIsDueSoon() {
        #expect(determineStatus(reminder(deadlineInDays: 0)) == .dueSoon(daysRemaining: 0))
    }
    
    // 2. Exactly at the threshold, it should still count as due soon
    @Test func deadlineInThreeDaysIsDueSoon() {
        #expect(determineStatus(reminder(deadlineInDays: 3)) == .dueSoon(daysRemaining: 3))
    }
    
    // 3. One day past the threshold, it becomes upcoming
    @Test func deadlineInFourDaysIsUpcoming() {
        #expect(determineStatus(reminder(deadlineInDays: 4)) == .upcoming(daysRemaining: 4))
    }
    
    // 4. Far away deadlines are upcoming and report the correct day count
    @Test func deadlineInTenDaysIsUpcoming() {
        #expect(determineStatus(reminder(deadlineInDays: 10)) == .upcoming(daysRemaining: 10))
    }
}
