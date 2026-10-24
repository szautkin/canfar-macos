// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// What a place may show (plan 49): a place that needs no account is always
/// open; one that does is open signed in, says so while a stored session is
/// checked or waits for the network, and is locked signed out.
final class PlaceAccessTests: XCTestCase {
    private func access(needsAccount: Bool = true, signedIn: Bool = false, checking: Bool = false,
                        waiting: Bool = false) -> iOSPlaceAccess {
        .of(needsAccount: needsAccount, signedIn: signedIn, checking: checking, waitingForNetwork: waiting)
    }

    func testAPlaceWithoutTheAccountIsAlwaysOpen() {
        for signedIn in [false, true] {
            for checking in [false, true] {
                for waiting in [false, true] {
                    XCTAssertEqual(access(needsAccount: false, signedIn: signedIn, checking: checking, waiting: waiting), .open)
                }
            }
        }
    }

    func testSignedInTheAccountsPlacesAreOpen() {
        XCTAssertEqual(access(signedIn: true), .open)
        XCTAssertEqual(access(signedIn: true, checking: true), .open, "renewing a live session leaves it open")
        XCTAssertEqual(access(signedIn: true, waiting: true), .open, "offline while signed in keeps it")
    }

    func testSignedOutTheyAreLockedOrSayWhy() {
        XCTAssertEqual(access(), .locked)
        XCTAssertEqual(access(checking: true), .checking, "no lock flashes while a stored session is checked")
        XCTAssertEqual(access(waiting: true), .waitingForNetwork)
        XCTAssertEqual(access(checking: true, waiting: true), .waitingForNetwork, "the network is the reason to say")
        XCTAssertTrue(access().isLocked)
        XCTAssertTrue(access(checking: true).isLocked)
        XCTAssertFalse(access(signedIn: true).isLocked)
    }
}
