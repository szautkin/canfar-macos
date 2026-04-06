// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class FITSTabHostModelTests: XCTestCase {

    func testAddTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        XCTAssertEqual(host.tabCount, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
    }

    func testAddMultipleTabs() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        XCTAssertEqual(host.tabCount, 2)
        XCTAssertEqual(host.activeTabIndex, 1, "New tab should be active")
    }

    func testCloseTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.closeTab(at: 0)
        XCTAssertEqual(host.tabCount, 1)
    }

    func testCloseActiveTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.closeActiveTab()
        XCTAssertEqual(host.tabCount, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
    }

    func testCloseLastTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.closeTab(at: 0)
        XCTAssertEqual(host.tabCount, 0)
        XCTAssertNil(host.activeTab)
    }

    func testActiveTab() {
        let host = FITSTabHostModel()
        let tab = host.addTab()
        XCTAssertTrue(host.activeTab === tab)
    }

    func testHasMultipleTabs() {
        let host = FITSTabHostModel()
        XCTAssertFalse(host.hasMultipleTabs)
        _ = host.addTab()
        XCTAssertFalse(host.hasMultipleTabs)
        _ = host.addTab()
        XCTAssertTrue(host.hasMultipleTabs)
    }

    func testCloseOutOfBoundsNoOp() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.closeTab(at: 99)
        XCTAssertEqual(host.tabCount, 1, "Out-of-bounds close should be no-op")
    }
}
