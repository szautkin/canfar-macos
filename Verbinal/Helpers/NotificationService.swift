// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import UserNotifications

enum NotificationService {
    private static let groupID = "com.codebg.Verbinal.headless"

    static func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    static func sendJobCompleted(sessionName: String, image: String) {
        let content = UNMutableNotificationContent()
        content.title = "Batch Job Completed"
        content.body = "\(sessionName) finished successfully"
        content.subtitle = shortImageLabel(image)
        content.sound = .default
        content.threadIdentifier = groupID

        send(id: "completed-\(sessionName)-\(Date().timeIntervalSince1970)", content: content)
    }

    static func sendJobFailed(sessionName: String, image: String) {
        let content = UNMutableNotificationContent()
        content.title = "Batch Job Failed"
        content.body = "\(sessionName) has failed"
        content.subtitle = shortImageLabel(image)
        content.sound = .default
        content.threadIdentifier = groupID
        content.interruptionLevel = .timeSensitive

        send(id: "failed-\(sessionName)-\(Date().timeIntervalSince1970)", content: content)
    }

    // MARK: - Private

    private static func send(id: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Extracts a short label from a container image URL (e.g. "astroml:latest" from "images.canfar.net/skaha/astroml:latest").
    private static func shortImageLabel(_ image: String) -> String {
        let parts = image.split(separator: "/")
        return String(parts.last ?? Substring(image))
    }
}
