// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Covers the conditional-rendering rules used by the Portal/Landing
/// toolbars: omit an empty status caption, and omit a blank account-menu
/// email row when the signed-in user has no email. Mirrors the
/// `if !statusMessage.isEmpty` / `if let email` guards in the landing
/// toolbar and `iOSAccountTab`.
final class ToolbarContentTests: XCTestCase {

    // MARK: - Status message

    func testStatusMessageHiddenWhenEmpty() {
        XCTAssertFalse(ToolbarContent.showsStatusMessage(""))
    }

    func testStatusMessageShownWhenPresent() {
        XCTAssertTrue(ToolbarContent.showsStatusMessage("Launching session…"))
    }

    func testStatusMessageShownForWhitespaceOnly() {
        // Whitespace is non-empty: behaviour-preserving with the existing
        // `!isEmpty` guard, which does not trim.
        XCTAssertTrue(ToolbarContent.showsStatusMessage(" "))
    }

    // MARK: - Account-menu email row

    func testAccountEmailHiddenWhenNil() {
        XCTAssertFalse(ToolbarContent.showsAccountEmail(nil))
    }

    func testAccountEmailShownWhenPresent() {
        XCTAssertTrue(ToolbarContent.showsAccountEmail("jane@example.org"))
    }

    func testAccountEmailShownEvenWhenEmptyString() {
        // An explicit empty-string email is still rendered (matches the
        // `if let email = info.email` guard, which only checks for nil),
        // documenting that the fix targets the nil case from the prior
        // `info.email ?? ""` fallback.
        XCTAssertTrue(ToolbarContent.showsAccountEmail(""))
    }
}
