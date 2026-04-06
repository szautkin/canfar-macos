// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class AppNavigationTests: XCTestCase {

    func testInitialModeIsLanding() {
        let state = AppState()
        XCTAssertEqual(state.currentMode, .landing)
    }

    func testCanGoBackFalseAtRoot() {
        let state = AppState()
        XCTAssertFalse(state.canGoBack)
    }

    func testNavigateToPushesStack() {
        let state = AppState()
        state.navigateTo(.search)
        XCTAssertEqual(state.currentMode, .search)
        XCTAssertTrue(state.canGoBack)
    }

    func testNavigateBackPopsStack() {
        let state = AppState()
        state.navigateTo(.search)
        state.navigateBack()
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertFalse(state.canGoBack)
    }

    func testNavigateBackAtRootNoOp() {
        let state = AppState()
        state.navigateBack() // should not crash
        XCTAssertEqual(state.currentMode, .landing)
    }

    func testMultiLevelNavigation() {
        let state = AppState()
        state.navigateTo(.search)
        state.navigateTo(.research)
        state.navigateTo(.fitsViewer)
        XCTAssertEqual(state.currentMode, .fitsViewer)

        state.navigateBack()
        XCTAssertEqual(state.currentMode, .research)

        state.navigateBack()
        XCTAssertEqual(state.currentMode, .search)

        state.navigateBack()
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertFalse(state.canGoBack)
    }

    func testDispatchOpenFITS() {
        let state = AppState()
        let url = URL(fileURLWithPath: "/tmp/test.fits")
        state.dispatch(.openFITS(url: url))
        XCTAssertEqual(state.currentMode, .fitsViewer)
        XCTAssertEqual(state.pendingFITSURL, url)
        XCTAssertTrue(state.canGoBack)
    }

    func testAllAppModesExist() {
        // Verify all 7 modes from Windows parity exist
        let modes: [AppMode] = [.landing, .search, .portal, .research, .storage, .fitsViewer, .notebook]
        XCTAssertEqual(modes.count, 7)
    }
}
