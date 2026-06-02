// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Exercises the MainActor-confined `PortalCacheRelativeFormatter` used by the
/// Settings ▸ Portal "Cached <relative time>" label. `RelativeDateTimeFormatter`
/// is documented as not thread-safe; these tests run on the MainActor to match
/// the formatter's thread-confinement contract and assert it produces a
/// non-empty, human-readable string for a known fetch date.
@MainActor
final class PortalCacheRelativeFormatterTests: XCTestCase {

    func testRelativeStringForPastDateIsNonEmpty() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)
        let result = PortalCacheRelativeFormatter.string(for: fiveMinutesAgo, relativeTo: now)
        XCTAssertFalse(result.isEmpty, "Relative string for a past date should be non-empty")
    }

    func testRelativeStringForFiveMinutesAgoMentionsMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveMinutesAgo = now.addingTimeInterval(-5 * 60)
        let result = PortalCacheRelativeFormatter.string(for: fiveMinutesAgo, relativeTo: now)
        // `.full` unitsStyle yields e.g. "5 minutes ago" in the en locale.
        XCTAssertTrue(
            result.localizedCaseInsensitiveContains("minute"),
            "Expected a minutes-based relative string, got: \(result)"
        )
    }

    func testRelativeStringIsStableForSameInputs() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fetchedAt = now.addingTimeInterval(-2 * 60 * 60)
        let first = PortalCacheRelativeFormatter.string(for: fetchedAt, relativeTo: now)
        let second = PortalCacheRelativeFormatter.string(for: fetchedAt, relativeTo: now)
        XCTAssertEqual(first, second, "Formatter should be deterministic for identical inputs")
    }
}
