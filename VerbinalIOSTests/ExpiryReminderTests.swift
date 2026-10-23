// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// When the session reminders come (plan 47 1.4), and how session times read.
final class ExpiryReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: String, expiresIn: TimeInterval?) -> PortalAttention.SessionFacts {
        PortalAttention.SessionFacts(id: id, name: "nb-\(id)", status: status, started: now,
                                     expires: expiresIn.map { now.addingTimeInterval($0) })
    }

    func testThirtyMinutesBeforeEachRunningSessionEnds() {
        let reminders = ExpiryReminderPlan.reminders(
            for: [session("b", "Running", expiresIn: 5 * 3600), session("a", "Running", expiresIn: 2 * 3600)], now: now)
        XCTAssertEqual(reminders.map(\.sessionID), ["a", "b"], "soonest first")
        XCTAssertEqual(reminders.first?.fireAt, now.addingTimeInterval(2 * 3600 - 30 * 60))
        XCTAssertEqual(reminders.first?.identifier, "verbinal.session-expiry.a")
    }

    func testNoneInsideTheLeadNorForWhatIsNotRunning() {
        let reminders = ExpiryReminderPlan.reminders(
            for: [session("inside", "Running", expiresIn: 20 * 60),
                  session("pending", "Pending", expiresIn: 4 * 3600),
                  session("unknown", "Running", expiresIn: nil),
                  session("failed", "Failed", expiresIn: 4 * 3600)], now: now)
        XCTAssertEqual(reminders, [])
    }

    func testSkahaTimesParseWithAndWithoutFractions() {
        XCTAssertEqual(SessionTimes.date("2026-10-22T18:00:00Z"), SessionTimes.date("2026-10-22T18:00:00.000Z"))
        XCTAssertNotNil(SessionTimes.date("2026-10-22T18:00:00Z"))
        XCTAssertNil(SessionTimes.date(""))
        XCTAssertNil(SessionTimes.date("tomorrow"))
    }

    func testWhatIsLeftReadsToTheMinute() {
        XCTAssertNil(SessionTimes.remaining(until: now, now: now), "ended")
        XCTAssertNil(SessionTimes.remaining(until: now.addingTimeInterval(-60), now: now))
        let soon = SessionTimes.remaining(until: now.addingTimeInterval(20), now: now)
        XCTAssertNotNil(soon, "under a minute still says a minute")
        XCTAssertTrue(soon?.contains("1") == true, soon ?? "")
        let later = SessionTimes.remaining(until: now.addingTimeInterval(2 * 3600 + 10 * 60), now: now)
        XCTAssertTrue(later?.contains("2") == true && later?.contains("10") == true, later ?? "")
    }
}
