//
//  ReminderStatus.swift
//  Folio
//
//  Created by Brandon Hua on 16/10/2026.
//

import Foundation

/// Works out whether a return reminder is upcoming, due soon or expired.
/// Where a return reminder sits relative to its deadline
enum ReturnReminderStatus: Equatable, Sendable {
    case upcoming(daysRemaining: Int) // more than 3 days left (subject to change)
    case dueSoon(daysRemaining: Int) // 0-3 days left (Can be changed later on)
    case expired // deadline has passed
}

@MainActor
struct DetermineReminderStatus {
    var calendar: Calendar = .current
    var now: () -> Date = Date.init // injectable so tests can fake "today"
    
    /// How many days a reminder counts as "due soon" before its deadline
    let dueSoonThreshold = 3
    
    func callAsFunction(_ reminder: ReturnReminder) -> ReturnReminderStatus{
        // Step A: strip the time off both dates so we compare whole days
        let today = calendar.startOfDay(for: now())
        let deadlineDay = calendar.startOfDay(for: reminder.deadline)
        
        // Step B: count calendar days between them
        let daysRemaining = calendar.dateComponents([.day], from: today, to: deadlineDay).day ?? 0
        
        // Step C: pick the status
        // if daysRemaining is below 0 → expired
        // else if daysRemaining is at or below the threshold → dueSoon
        // else → upcoming
        if daysRemaining < 0 {
            return .expired
        } else if daysRemaining <= dueSoonThreshold {
            return .dueSoon(daysRemaining: daysRemaining)
        } else {
            return .upcoming(daysRemaining: daysRemaining)
        }

    }
}
