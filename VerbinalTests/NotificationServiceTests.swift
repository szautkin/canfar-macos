// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class NotificationServiceTests: XCTestCase {

    func testMultiSegmentURLReturnsLastSegment() {
        XCTAssertEqual(
            NotificationService.shortImageLabel("images.canfar.net/skaha/astroml:latest"),
            "astroml:latest"
        )
    }

    func testSingleSegmentWithoutSlashReturnsInput() {
        XCTAssertEqual(
            NotificationService.shortImageLabel("astroml:latest"),
            "astroml:latest"
        )
    }

    func testEmptyStringReturnsEmptyString() {
        XCTAssertEqual(NotificationService.shortImageLabel(""), "")
    }

    func testTrailingSlashFallsBackToOriginalString() {
        XCTAssertEqual(
            NotificationService.shortImageLabel("images.canfar.net/skaha/"),
            "images.canfar.net/skaha/"
        )
    }
}
