// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import UserNotifications

/// The session-expiry reminders, on the person's word (plan 47 1.4): off
/// until they turn them on, which is when iOS asks for permission.
@Observable
@MainActor
final class ExpiryReminderScheduler {
    static let enabledKey = "ios.reminders.sessionExpiry"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    /// On, and allowed by iOS.
    private(set) var isEnabled: Bool
    /// iOS refused, or the person turned notifications off in Settings.
    private(set) var isDenied = false

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Turns the reminders on (asking iOS the first time) or off. Off
    /// removes every reminder waiting.
    func setEnabled(_ on: Bool, sessions: [PortalAttention.SessionFacts]) async {
        guard on else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            await removeAll()
            return
        }
        let allowed = await requestPermission()
        isDenied = !allowed
        isEnabled = allowed
        defaults.set(allowed, forKey: Self.enabledKey)
        if allowed { await reschedule(sessions) }
    }

    /// The reminders for these sessions, and no others: called after every
    /// load, renew and delete.
    func reschedule(_ sessions: [PortalAttention.SessionFacts], now: Date = Date()) async {
        guard isEnabled else { return }
        await removeAll()
        for reminder in ExpiryReminderPlan.reminders(for: sessions, now: now) {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(reminder.sessionName) expires in 30 minutes")
            content.body = String(localized: "Renew it in Verbinal, or save your work.")
            content.sound = .default
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                       from: reminder.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }
    }

    private func removeAll() async {
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(ExpiryReminderPlan.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    private func requestPermission() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }
}

/// Shows Verbinal's notifications while it is in front too: iOS keeps them
/// out of sight otherwise.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
