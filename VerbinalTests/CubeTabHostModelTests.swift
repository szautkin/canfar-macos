// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Agent open/rollback on the Cube Viewer tab host (shared policy in
/// `ViewerTabHosting`; the FITS side is covered in FITSTabHostModelTests).
@MainActor
final class CubeTabHostModelTests: XCTestCase {

    func testFailedOpenIsDiscardedAndLeavesPlaceholder() async throws {
        let host = CubeTabHostModel()
        XCTAssertEqual(host.tabs.count, 1)
        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertEqual(host.tabs.count, 1, "placeholder tab remains; failed tab is gone")
        XCTAssertFalse(host.activeTab.hasData)
        XCTAssertNil(host.activeTab.loadError)
    }

    /// Plan 17 U3 (QA N6): a cube opened leaves no empty tab beside it,
    /// and `list_open_tabs` never lists one with no path.
    func testOpeningACubeReplacesTheEmptyTab() async throws {
        let host = CubeTabHostModel()
        let url = try FITSTestFixtures.writeCube()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNil(err)
        XCTAssertEqual(host.tabPaths, [url.path], "no ghost tab with an empty path")
        XCTAssertEqual(host.activeTabIndex, 0)
        XCTAssertTrue(host.activeTab.hasData)
    }

    func testFailedOpenRestoresPreviouslyFocusedTab() async throws {
        let host = CubeTabHostModel()
        let first = host.activeTab
        host.tabs.append(CubeViewerModel())
        host.activeTabIndex = 0

        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertEqual(host.tabs.count, 2)
        XCTAssertTrue(host.activeTab === first, "focus returns to the tab the user was on, not the last tab")
    }
}
