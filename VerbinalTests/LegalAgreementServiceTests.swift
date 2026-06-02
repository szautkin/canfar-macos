// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Coverage for the versioned Terms-of-Use acceptance gate.
@MainActor
final class LegalAgreementServiceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "legal.tests.\(UUID().uuidString)")!
    }

    func testFreshInstallNotAccepted() {
        let svc = LegalAgreementService(defaults: makeDefaults())
        XCTAssertFalse(svc.hasAcceptedCurrent, "a fresh install must show the gate")
        XCTAssertNil(svc.acceptedAt)
    }

    func testAcceptPersistsCurrentVersionAndTimestamp() {
        let defaults = makeDefaults()
        let svc = LegalAgreementService(defaults: defaults)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        svc.accept(now: when)

        XCTAssertTrue(svc.hasAcceptedCurrent)
        XCTAssertEqual(svc.acceptedVersion, LegalText.version)
        XCTAssertEqual(svc.acceptedAt, when)

        // A new instance reading the same defaults observes the acceptance.
        let reopened = LegalAgreementService(defaults: defaults)
        XCTAssertTrue(reopened.hasAcceptedCurrent)
        XCTAssertEqual(reopened.acceptedVersion, LegalText.version)
    }

    func testOlderAcceptedVersionRePrompts() {
        let defaults = makeDefaults()
        // Simulate a user who accepted an earlier Terms version.
        defaults.set(LegalText.version - 1, forKey: "legal.acceptedTermsVersion")
        let svc = LegalAgreementService(defaults: defaults)
        XCTAssertFalse(svc.hasAcceptedCurrent, "an older accepted version must re-prompt")
    }

    func testResetClearsAcceptance() {
        let defaults = makeDefaults()
        let svc = LegalAgreementService(defaults: defaults)
        svc.accept()
        XCTAssertTrue(svc.hasAcceptedCurrent)

        svc.reset()
        XCTAssertFalse(svc.hasAcceptedCurrent)
        XCTAssertNil(svc.acceptedAt)
    }

    func testCurrentVersionTracksLegalText() {
        XCTAssertEqual(LegalAgreementService.currentVersion, LegalText.version)
    }
}
