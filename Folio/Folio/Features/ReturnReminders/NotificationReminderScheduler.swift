//
//  NotificationReminderScheduler.swift
//  Folio
//
//  Created by Brandon Hua on 16/10/2026.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationReminderScheduler: ReminderScheduling {
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    //ask the user for permission to show reminders
    // iOS only shows the pop-up once. Returns saved answers any time after.
    func requestAuthorization() async throws -> Bool {
        return try await notificationCenter.requestAuthorization(options: [.alert, .sound])
    }
    
    func schedule(_ reminder: ReturnReminder) async throws {
        
        //1. Don't schedule if the user has not allowed notifications
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            throw FolioError.notificationsUnavailable
        }
    }
    
    func cancel(id: UUID) async {
        
        // Remove the reminder so it never fires. E.g. User deleted notification or marked as returned.
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        
        //Also clear it from Notification Centre if it has already been shown.
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
    
}
