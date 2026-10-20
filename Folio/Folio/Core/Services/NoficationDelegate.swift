//
//  NoficationDelegate.swift
//  Folio
//
//  Created by Ziyan Nadeem on 21/10/2026.
//

import UserNotifications

/// Presents return reminder banners and plays notification sounds even when the app is open in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    
    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
