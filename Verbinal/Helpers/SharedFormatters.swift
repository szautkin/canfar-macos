// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// App-wide shared formatters.
///
/// Background: a quality audit found 11+ ad-hoc `DateFormatter` declarations
/// (some static, some instantiated per call) and 6 `ByteCountFormatter` call
/// sites scattered across modules. Apart from the obvious DRY problem,
/// instantiating a `DateFormatter` per cell render allocates noticeably
/// during scrolls. This namespace hosts the canonical instances so call
/// sites just reference `SharedFormatters.iso.date(from: …)` etc.
///
/// All formatters here are `@unchecked Sendable` — Foundation's formatters
/// are documented thread-safe for the read-only API surface we use; we never
/// reach into them after construction.
enum SharedFormatters {

    // MARK: - Dates

    // Apple's `ISO8601DateFormatter` and `ByteCountFormatter` are
    // documented thread-safe after configuration; the strict-
    // concurrency check can't infer that, so we mark the immutable
    // statics `nonisolated(unsafe)`. Read-only after the
    // once-initialiser runs.

    /// ISO-8601 with internet date-time + fractional seconds, e.g.
    /// `2024-03-15T10:30:45.123Z`. Use for parsing CADC/CAOM2 timestamps.
    nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO-8601 with internet date-time, no fractional seconds.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `yyyy-MM-dd` UTC, no time-of-day. Use for date-only display.
    static let yyyyMMddUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// `yyyy-MM-dd HH:mm:ss` UTC. Use for full observation timestamps.
    static let yyyyMMddHHmmssUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// User-locale medium-style date (e.g., "Apr 27, 2026"). For UI display.
    static let userMediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// User-locale medium date + short time (e.g., "Apr 27, 2026 at 10:30 AM").
    static let userMediumDateShortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Bytes

    /// File-size byte-count formatter — used everywhere a cell shows a
    /// human-readable size (downloads, artifacts, VOSpace nodes).
    nonisolated(unsafe) static let fileBytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    /// Convenience for `fileBytes.string(fromByteCount:)`.
    static func bytes(_ count: Int64) -> String {
        fileBytes.string(fromByteCount: count)
    }
}
