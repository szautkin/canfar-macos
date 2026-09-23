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

    // MARK: - syncUsesImpreciseWCS

    func testSyncWCSWarning_OffWhenNoSyncMode() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        // No sync mode active → never warns, even with WCS-less tabs.
        XCTAssertFalse(host.syncUsesImpreciseWCS)
    }

    func testSyncWCSWarning_OffWithSingleTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.linkedState.linkCrosshair = true
        // A lone tab has nothing to sync against.
        XCTAssertFalse(host.syncUsesImpreciseWCS)
    }

    func testSyncWCSWarning_OnWhenLinkedTabLacksWCS() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        // Empty tabs have no WCS; with a sync mode on that is imprecise.
        host.linkedState.linkCrosshair = true
        XCTAssertTrue(host.syncUsesImpreciseWCS)
        // Also fires for the zoom-sync mode.
        host.linkedState.linkCrosshair = false
        host.linkedState.linkZoom = true
        XCTAssertTrue(host.syncUsesImpreciseWCS)
    }

    func testOpenFileKeepsFailedTabForUIRetry() async throws {
        let host = FITSTabHostModel()
        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let tab = await host.openFile(url: url)
        XCTAssertEqual(host.tabCount, 1)
        XCTAssertNotNil(tab.loadError)
        XCTAssertNil(tab.file)
        XCTAssertTrue(host.activeTab === tab)
    }

    func testOpenFileDiscardingFailureRemovesDeadTab() async throws {
        let host = FITSTabHostModel()
        _ = host.addTab()
        XCTAssertEqual(host.tabCount, 1)

        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.isEmpty == false)
        XCTAssertEqual(host.tabCount, 1, "the pre-existing tab stays; the failed tab is gone")
        XCTAssertNil(host.activeTab?.loadError)
        XCTAssertNil(host.activeTab?.file)
    }

    func testOpenFileDiscardingFailureOnEmptyHostLeavesNoTab() async throws {
        let host = FITSTabHostModel()
        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertEqual(host.tabCount, 0)
        XCTAssertNil(host.activeTab)
    }

    func testOpenFileDiscardingFailureRestoresPreviouslyFocusedTab() async throws {
        // Closing the dead tab alone would land on the LAST tab; the agent
        // rollback must hand focus back to the tab the user was on.
        let host = FITSTabHostModel()
        let first = host.addTab()
        _ = host.addTab()
        host.activeTabIndex = 0

        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertEqual(host.tabCount, 2)
        XCTAssertTrue(host.activeTab === first)
    }

    func testLinkedPixelCrosshairReadsTheDrawnPixel() {
        // No WCS → pixel-only link. The value must come from the row the
        // renderer draws at that display position, not the mirrored row.
        let host = FITSTabHostModel()
        let source = host.addTab()
        let target = host.addTab()
        FITSTestFixtures.loadRamp(into: source)
        FITSTestFixtures.loadRamp(into: target)
        host.linkedState.linkCrosshair = true
        host.activeTabIndex = 0

        host.writePixelToStore(from: source, pixel: CGPoint(x: 3, y: 0))
        host.activeTabIndex = 1

        let expected = FITSTestFixtures.rampValue(x: 3, y: 99)
        XCTAssertEqual(target.crosshairValue, FITSViewerModel.formatPixelValue(expected))
    }
}
