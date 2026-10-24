// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// The welcome (plan 50): when it shows, the Mac's rule shared, and what it
/// says: what works without an account first, then what an account adds.
final class WelcomeTests: XCTestCase {
    private let current = WelcomePreferences.currentVersion

    func testItShowsOnceAfterTheTermsWithNoOtherSheetUp() {
        XCTAssertTrue(WelcomePreferences.shouldShow(seenVersion: 0, termsAccepted: true, sheetUp: false))
        XCTAssertTrue(WelcomePreferences.shouldShow(seenVersion: current - 1, termsAccepted: true, sheetUp: false),
                      "a newer welcome shows to those who saw an older one")
        XCTAssertFalse(WelcomePreferences.shouldShow(seenVersion: current, termsAccepted: true, sheetUp: false),
                       "seen this version")
        XCTAssertFalse(WelcomePreferences.shouldShow(seenVersion: 0, termsAccepted: false, sheetUp: false),
                       "never before the Terms")
        XCTAssertFalse(WelcomePreferences.shouldShow(seenVersion: 0, termsAccepted: true, sheetUp: true),
                       "never over another sheet")
    }

    func testWhatWorksWithoutAnAccountComesFirst() {
        let free = iOSWelcomeItem.rows(needingAccount: false).map(\.id)
        let account = iOSWelcomeItem.rows(needingAccount: true).map(\.id)
        XCTAssertEqual(free, ["fits", "cube", "files", "samples"])
        XCTAssertEqual(account, ["account"])
        XCTAssertEqual(iOSWelcomeItem.all.map(\.id), free + account, "the account's row comes after the rest")
    }

    func testEveryRowSaysSomething() {
        let ids = iOSWelcomeItem.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no row twice")
        for item in iOSWelcomeItem.all {
            XCTAssertFalse(String(localized: item.title).isEmpty, item.id)
            XCTAssertFalse(String(localized: item.detail).isEmpty, item.id)
            XCTAssertFalse(item.symbol.isEmpty, item.id)
        }
    }
}
