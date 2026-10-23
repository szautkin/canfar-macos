// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// When to tell the person a session is about to end (plan 47 1.4). Each
/// session's expiry is known ahead, so the reminders are scheduled with the
/// system and come whether Verbinal runs or not.
enum ExpiryReminderPlan {
    /// How long before the end the reminder comes.
    static let lead: TimeInterval = 30 * 60
    /// What every reminder's identifier starts with, so a new plan replaces
    /// exactly the old one.
    static let identifierPrefix = "verbinal.session-expiry."

    struct Reminder: Equatable, Sendable {
        let sessionID: String
        let sessionName: String
        let fireAt: Date
        let expires: Date

        var identifier: String { ExpiryReminderPlan.identifierPrefix + sessionID }
    }

    /// One reminder per running session whose reminder time is still to
    /// come. A session already inside the lead has none: the Portal shows
    /// it under Needs attention while the person is there.
    static func reminders(for sessions: [PortalAttention.SessionFacts], now: Date = Date()) -> [Reminder] {
        sessions.compactMap { session in
            guard session.isRunning, let end = session.expires else { return nil }
            let fireAt = end.addingTimeInterval(-lead)
            guard fireAt > now else { return nil }
            return Reminder(sessionID: session.id, sessionName: session.name, fireAt: fireAt, expires: end)
        }
        .sorted { $0.fireAt < $1.fireAt }
    }
}
