// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Covers the conditional-rendering rules the Portal/Landing toolbars call:
/// omit an empty status caption.
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
}
