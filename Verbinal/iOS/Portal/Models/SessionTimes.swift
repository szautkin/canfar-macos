// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Skaha's times as dates, and what is left of a session, as a person reads it.
enum SessionTimes {
    /// An ISO 8601 time from Skaha, with or without fractional seconds.
    static func date(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// "38 min", "2 hr, 10 min": the time from `now` to `end`, to the minute;
    /// nil once it has passed.
    static func remaining(until end: Date, now: Date = Date()) -> String? {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        // Under a minute still reads as a minute, not "0 min".
        return formatter.string(from: max(seconds, 60))
    }
}
