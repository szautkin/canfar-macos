// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

@MainActor
final class AppNavigationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainStorage.clearToken()
    }

    override func tearDown() {
        KeychainStorage.clearToken()
        super.tearDown()
    }

    func testInitialModeIsLanding() {
        let state = AppState()
        XCTAssertEqual(state.currentMode, .landing)
    }

    func testNavigateToSwitchesMode() {
        let state = AppState()
        state.navigateTo(.search)
        XCTAssertEqual(state.currentMode, .search)
    }

    func testNavigateBackReturnsToLanding() {
        let state = AppState()
        state.navigateTo(.search)
        state.navigateBack()
        XCTAssertEqual(state.currentMode, .landing)
    }

    func testNavigateBackAtRootNoOp() {
        let state = AppState()
        state.navigateBack() // should not crash
        XCTAssertEqual(state.currentMode, .landing)
    }

    func testNavigateBackAlwaysGoesHome() {
        let state = AppState()
        state.navigateTo(.search)
        state.navigateTo(.research)
        state.navigateTo(.fitsViewer)
        XCTAssertEqual(state.currentMode, .fitsViewer)

        // navigateBack() always goes home, however deep the user went.
        state.navigateBack()
        XCTAssertEqual(state.currentMode, .landing)
    }

    func testDispatchOpenFITS() {
        let state = AppState()
        let url = URL(fileURLWithPath: "/tmp/test.fits")
        state.dispatch(.openFITS(url: url))
        XCTAssertEqual(state.currentMode, .fitsViewer)
        XCTAssertEqual(state.pendingFITSURL, url)
    }

    func testOpenPendingViewerChoiceAsFITSClearsSheetAndNavigates() {
        let state = AppState()
        let url = URL(fileURLWithPath: "/tmp/cube.fits")
        state.pendingViewerChoiceURL = url
        state.openPendingViewerChoiceAsFITS()
        XCTAssertNil(state.pendingViewerChoiceURL)
        XCTAssertEqual(state.currentMode, .fitsViewer)
        XCTAssertEqual(state.pendingFITSURL, url)
    }

    func testOpenPendingViewerChoiceAsCubeClearsSheetAndNavigates() {
        let state = AppState()
        let url = URL(fileURLWithPath: "/tmp/cube.fits")
        state.pendingViewerChoiceURL = url
        state.openPendingViewerChoiceAsCube()
        XCTAssertNil(state.pendingViewerChoiceURL)
        XCTAssertEqual(state.currentMode, .cubeViewer)
        XCTAssertEqual(state.pendingCubeURL, url)
    }

    func testOpenAstronomyFITSWithExplicitViewerSkipsSheet() async {
        let state = AppState()
        let url = URL(fileURLWithPath: "/tmp/cube-\(UUID().uuidString).fits")
        do {
            _ = try await state.openAstronomyFITSAwaitingChoice(url: url, viewer: .cube)
            XCTFail("missing file must not report opened")
        } catch {
            XCTAssertNil(state.pendingViewerChoiceURL)
            XCTAssertEqual(state.currentMode, .cubeViewer)
            XCTAssertNil(state.pendingCubeURL)
        }
    }

    func testViewerChoiceAgentNoteNamesChooseViewer() {
        let note = AppState.viewerChoiceAgentNote(filename: "cube.fits")
        XCTAssertTrue(note.contains("choose_viewer"))
        XCTAssertTrue(note.contains("cube.fits"))
    }

    func testAllAppModesExist() {
        // Six modes in the slim Verbinal SKU. The .notebook mode exists only in
        // Verbinal Pi (which also ships the bundled Python kernel).
        let modes: [AppMode] = [.landing, .search, .portal, .research, .storage, .fitsViewer]
        XCTAssertEqual(modes.count, 6)
    }

    // MARK: - Auth-gated mode leave (Portal / Storage)

    func testLeaveAuthGatedModesFromPortalRemembersDestination() {
        let state = AppState()
        state.navigateTo(.portal)
        state.leaveAuthGatedModesIfNeeded(rememberForRelogin: true)
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertEqual(state.pendingModeAfterLogin, .portal)
    }

    func testLeaveAuthGatedModesFromStorageWithoutRemember() {
        let state = AppState()
        state.navigateTo(.storage)
        state.leaveAuthGatedModesIfNeeded(rememberForRelogin: false)
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertNil(state.pendingModeAfterLogin)
    }

    func testLeaveAuthGatedModesNoOpOnFreeModules() {
        let state = AppState()
        state.navigateTo(.search)
        state.leaveAuthGatedModesIfNeeded(rememberForRelogin: true)
        XCTAssertEqual(state.currentMode, .search)
        XCTAssertNil(state.pendingModeAfterLogin)
    }

    func testLogoutLeavesPortalWithoutPendingRelogin() async {
        let state = AppState()
        state.navigateTo(.portal)
        state.pendingModeAfterLogin = .portal
        await state.logout()
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertNil(state.pendingModeAfterLogin)
    }

    func testSessionExpiredLeavesPortalAndRemembersDestination() async throws {
        // No Keychain token → silentReauth returns .sessionExpired.
        let state = AppState()
        state.updateAuthState(username: "alice", userInfo: nil)
        state.navigateTo(.portal)
        XCTAssertTrue(state.isAuthenticated)

        state.handleTokenExpired()
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertEqual(state.pendingModeAfterLogin, .portal)
        XCTAssertTrue(state.showLoginSheet)
    }

    // MARK: - Pending restore after login

    func testAfterAuthenticatedRestoresPendingFromLanding() {
        let state = AppState()
        state.pendingModeAfterLogin = .portal
        XCTAssertEqual(state.currentMode, .landing)
        state.updateAuthState(username: "alice", userInfo: nil)
        XCTAssertEqual(state.currentMode, .portal)
        XCTAssertNil(state.pendingModeAfterLogin)
    }

    func testAfterAuthenticatedDoesNotHijackFreeModule() {
        let state = AppState()
        state.pendingModeAfterLogin = .portal
        state.navigateTo(.search)
        // navigateTo(.search) clears pending; re-set to simulate expiry leave
        // that set pending, then the user moved to Search before login completed.
        state.pendingModeAfterLogin = .portal
        state.updateAuthState(username: "alice", userInfo: nil)
        XCTAssertEqual(state.currentMode, .search)
        XCTAssertNil(state.pendingModeAfterLogin)
    }

    func testNavigateToFreeModuleClearsPending() {
        let state = AppState()
        state.pendingModeAfterLogin = .storage
        state.navigateTo(.research)
        XCTAssertNil(state.pendingModeAfterLogin)
        XCTAssertEqual(state.currentMode, .research)
    }

    func testNavigateToGatedModePreservesPending() {
        let state = AppState()
        // Signed-out tile path sets pending then, after login, navigates —
        // navigating to the gated mode itself must not clear the intent mid-flight.
        state.pendingModeAfterLogin = .storage
        state.navigateTo(.storage)
        XCTAssertEqual(state.pendingModeAfterLogin, .storage)
    }

    // MARK: - Auth-gated mode policy

    func testRequiresAuthenticationOnlyPortalAndStorage() {
        XCTAssertTrue(AppMode.portal.requiresAuthentication)
        XCTAssertTrue(AppMode.storage.requiresAuthentication)
        for mode: AppMode in [.landing, .search, .research, .fitsViewer, .cubeViewer, .aiGuide, .workflows] {
            XCTAssertFalse(mode.requiresAuthentication, "\(mode) must be open without login")
        }
    }

    func testNavigateOrPromptLoginWhenSignedOutSetsPendingAndSheet() {
        let state = AppState()
        XCTAssertFalse(state.isAuthenticated)
        state.navigateOrPromptLogin(.portal)
        XCTAssertEqual(state.currentMode, .landing)
        XCTAssertEqual(state.pendingModeAfterLogin, .portal)
        XCTAssertTrue(state.showLoginSheet)
    }

    func testNavigateOrPromptLoginWhenSignedInNavigates() {
        let state = AppState()
        state.updateAuthState(username: "alice", userInfo: nil)
        state.navigateOrPromptLogin(.storage)
        XCTAssertEqual(state.currentMode, .storage)
        XCTAssertNil(state.pendingModeAfterLogin)
    }
}
