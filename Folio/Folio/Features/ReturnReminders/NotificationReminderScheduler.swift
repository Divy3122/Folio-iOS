//
//  NotificationReminderScheduler.swift
//  Folio
//
//  Created by Brandon Hua on 16/10/2026.
//

import Foundation
import UserNotifications

///Schedules return-deadline reminders as local notifications.
@MainActor
final class NotificationReminderScheduler: ReminderScheduling {
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    // Ask the user for permission to show reminders
    // iOS only shows the pop-up once. Returns saved answers any time after.
    func requestAuthorization() async throws -> Bool {
        return try await notificationCenter.requestAuthorization(options: [.alert, .sound])
    }
    
    func schedule(_ reminder: ReturnReminder) async throws {
        
        // 1. Don't schedule if the user has not allowed notifications
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            throw FolioError.notificationsUnavailable
        }
        
        // 2. What the user sees on the notification
        let content = UNMutableNotificationContent()
        content.title = "Return Deadline Coming Up"
        
        // Turn the deadline into readable text, e.g. "23 Oct 2026"
        let deadlineText = reminder.deadline.formatted(date: .abbreviated, time: .omitted)
        content.body = "Your last day to return this item is \(deadlineText)."
        
        content.sound = UNNotificationSound.default
        
        // 3. When the notification should fire
        let fireDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: reminder.notifyAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: fireDateComponents, repeats: false)
        
        // 4. Package everything up and hand to iOS
        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)
        try await notificationCenter.add(request)
    }
    
    func cancel(id: UUID) async {
        
        // Remove the reminder so it never fires. E.g. User deleted notification or marked as returned.
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        
        // Also clear it from Notification Centre if it has already been shown.
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
    
}
