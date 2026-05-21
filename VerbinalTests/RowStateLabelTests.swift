// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for the row-status UX helpers added in Phase 2 of the
/// 2026-05-20 UX audit: time-ago formatter, category labels, and
/// the "is the grace-poll task likely still working on this?"
/// heuristic. All three are static and pure — pin the contract so
/// future refactors of the failure-chip render path can't silently
/// regress what the picky-astronomer user reads at a glance.
final class RowStateLabelTests: XCTestCase {

    // MARK: - timeAgo

    func testTimeAgoJustNow() {
        let now = Date()
        XCTAssertEqual(ImageDiscoveryModel.timeAgo(now, now: now), "just now")
    }

    func testTimeAgoSeconds() {
        let now = Date()
        let past = now.addingTimeInterval(-42)
        XCTAssertEqual(ImageDiscoveryModel.timeAgo(past, now: now), "42s ago")
    }

    func testTimeAgoMinutes() {
        let now = Date()
        let past = now.addingTimeInterval(-5 * 60)
        XCTAssertEqual(ImageDiscoveryModel.timeAgo(past, now: now), "5m ago")
    }

    func testTimeAgoHours() {
        let now = Date()
        let past = now.addingTimeInterval(-3 * 3_600)
        XCTAssertEqual(ImageDiscoveryModel.timeAgo(past, now: now), "3h ago")
    }

    func testTimeAgoDays() {
        let now = Date()
        let past = now.addingTimeInterval(-2 * 86_400)
        XCTAssertEqual(ImageDiscoveryModel.timeAgo(past, now: now), "2d ago")
    }

    /// Past the 14-day window the formatter falls back to a short
    /// absolute date. Pin the format pattern (`MMM d`) — we don't
    /// want "yesterday at 8:34 AM" verbosity in a sidebar-density
    /// row.
    func testTimeAgoOlderThanTwoWeeksUsesAbsoluteDate() {
        let now = Date()
        let past = now.addingTimeInterval(-30 * 86_400)
        let label = ImageDiscoveryModel.timeAgo(past, now: now)
        // Should NOT contain "ago"
        XCTAssertFalse(label.contains("ago"),
                       "older-than-14d should switch to absolute date; got '\(label)'")
        // Should match "MMM d" — short month abbreviation + day number.
        let regex = #/^[A-Z][a-z]{2} \d{1,2}$/#
        XCTAssertNotNil(try? regex.firstMatch(in: label),
                        "absolute fallback should match 'MMM d' pattern; got '\(label)'")
    }

    /// Future timestamps (clock skew, server time ahead of client)
    /// don't crash — they read as "just now". Defends against
    /// negative-elapsed math elsewhere in the formatter.
    func testTimeAgoFutureClockSkewReadsAsJustNow() {
        let now = Date()
        let future = now.addingTimeInterval(30)
        XCTAssertEqual(ImageDiscoveryModel.timeAgo(future, now: now), "just now")
    }

    // MARK: - categoryLabel

    /// Every category has a non-empty label. A future enum-case
    /// addition that misses a switch arm would surface here.
    func testEveryFailureCategoryHasNonEmptyLabel() {
        for category in LastOutcome.FailureCategory.allCases {
            let label = ImageDiscoveryModel.categoryLabel(category)
            XCTAssertFalse(label.isEmpty,
                           "missing label for category \(category)")
        }
    }

    /// QA-named cases get the canonical short labels the user
    /// already saw in mocks / spec discussion. Locking the strings
    /// prevents accidental rename.
    func testCategoryLabelsForKnownCases() {
        XCTAssertEqual(
            ImageDiscoveryModel.categoryLabel(.jobTimedOut),
            "Timed out"
        )
        XCTAssertEqual(
            ImageDiscoveryModel.categoryLabel(.jobSubmitFailed),
            "Submit failed"
        )
        XCTAssertEqual(
            ImageDiscoveryModel.categoryLabel(.manifestFetchFailed),
            "No manifest"
        )
        XCTAssertEqual(
            ImageDiscoveryModel.categoryLabel(.manifestParseFailed),
            "Bad manifest"
        )
    }

    // MARK: - isLikelyStillRecovering

    /// jobTimedOut failure within the 10-minute grace window →
    /// the row UI shows "checking in background".
    func testRecentTimeoutLikelyRecovering() {
        let now = Date()
        let recent = now.addingTimeInterval(-3 * 60)  // 3 min ago
        XCTAssertTrue(
            ImageDiscoveryModel.isLikelyStillRecovering(
                category: .jobTimedOut,
                attemptedAt: recent,
                now: now
            )
        )
    }

    /// Timeout that's already past the grace deadline → the
    /// coordinator's grace task has self-exited; row shows
    /// plain "Timed out" without the recovery hint.
    func testStaleTimeoutNoLongerRecovering() {
        let now = Date()
        let stale = now.addingTimeInterval(-15 * 60)  // 15 min ago
        XCTAssertFalse(
            ImageDiscoveryModel.isLikelyStillRecovering(
                category: .jobTimedOut,
                attemptedAt: stale,
                now: now
            )
        )
    }

    /// Non-timeout categories never get the "recovering" hint —
    /// auth failures, parse failures, etc. don't auto-resolve with
    /// time.
    func testNonTimeoutCategoriesNeverRecovering() {
        let now = Date()
        let recent = now.addingTimeInterval(-1 * 60)
        for category: LastOutcome.FailureCategory in [
            .jobSubmitFailed, .manifestFetchFailed,
            .manifestParseFailed, .cancelled, .unknown
        ] {
            XCTAssertFalse(
                ImageDiscoveryModel.isLikelyStillRecovering(
                    category: category, attemptedAt: recent, now: now
                ),
                "category \(category) must never read as recovering"
            )
        }
    }
}
