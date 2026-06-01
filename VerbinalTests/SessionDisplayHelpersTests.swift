// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import SwiftUI
@testable import Verbinal

/// Unit coverage for the pure `SessionDisplay` helper namespace that drives the
/// session list status colours/labels, type icons/assets, and start-time text.
final class SessionDisplayHelpersTests: XCTestCase {

    // MARK: - Status Color

    func testStatusColorRunningIsGreen() {
        XCTAssertEqual(SessionDisplay.statusColor("running"), .green)
    }

    func testStatusColorIsCaseInsensitive() {
        XCTAssertEqual(SessionDisplay.statusColor("RUNNING"), .green)
        XCTAssertEqual(SessionDisplay.statusColor("PENDING"), .orange)
        XCTAssertEqual(SessionDisplay.statusColor("Failed"), .red)
    }

    func testStatusColorFailedAndErrorAreRed() {
        XCTAssertEqual(SessionDisplay.statusColor("failed"), .red)
        XCTAssertEqual(SessionDisplay.statusColor("error"), .red)
    }

    func testStatusColorTerminatingIsGray() {
        XCTAssertEqual(SessionDisplay.statusColor("terminating"), .gray)
    }

    func testStatusColorUnknownDefaultsToGray() {
        XCTAssertEqual(SessionDisplay.statusColor("something-novel"), .gray)
    }

    // MARK: - Status Localization

    func testLocalizedStatusKnownCasesAreNonEmpty() {
        // Localized output varies with locale; assert non-empty mapping rather
        // than a fixed English string so the test is locale-independent.
        for status in ["running", "pending", "failed", "error", "completed",
                       "succeeded", "terminated", "terminating", "stopped"] {
            XCTAssertFalse(SessionDisplay.localizedStatus(status).isEmpty,
                           "Expected non-empty localized string for \(status)")
        }
    }

    func testLocalizedStatusIsCaseInsensitive() {
        // "RUNNING" and "running" must hit the same catalog entry.
        XCTAssertEqual(SessionDisplay.localizedStatus("RUNNING"),
                       SessionDisplay.localizedStatus("running"))
        XCTAssertEqual(SessionDisplay.localizedStatus("Failed"),
                       SessionDisplay.localizedStatus("error"))
    }

    func testLocalizedStatusUnknownPassesThroughVerbatim() {
        XCTAssertEqual(SessionDisplay.localizedStatus("QuantumState"), "QuantumState")
    }

    // MARK: - Type Color

    func testTypeColorKnownTypes() {
        XCTAssertEqual(SessionDisplay.typeColor("notebook"), .blue)
        XCTAssertEqual(SessionDisplay.typeColor("desktop"), .purple)
        XCTAssertEqual(SessionDisplay.typeColor("carta"), .teal)
        XCTAssertEqual(SessionDisplay.typeColor("contributed"), Color(.systemOrange))
        XCTAssertEqual(SessionDisplay.typeColor("firefly"), .orange)
    }

    func testTypeColorIsCaseInsensitive() {
        XCTAssertEqual(SessionDisplay.typeColor("NOTEBOOK"), .blue)
    }

    func testTypeColorUnknownDefaultsToSecondary() {
        XCTAssertEqual(SessionDisplay.typeColor("mystery"), .secondary)
    }

    // MARK: - Type Image Asset

    func testTypeImageAssetKnownTypes() {
        XCTAssertEqual(SessionDisplay.typeImageAsset("notebook"), "session-notebook")
        XCTAssertEqual(SessionDisplay.typeImageAsset("desktop"), "session-desktop")
        XCTAssertEqual(SessionDisplay.typeImageAsset("carta"), "session-carta")
        XCTAssertEqual(SessionDisplay.typeImageAsset("contributed"), "session-contributed")
        XCTAssertEqual(SessionDisplay.typeImageAsset("firefly"), "session-firefly")
    }

    func testTypeImageAssetIsCaseInsensitive() {
        XCTAssertEqual(SessionDisplay.typeImageAsset("Notebook"), "session-notebook")
    }

    func testTypeImageAssetUnknownIsNil() {
        XCTAssertNil(SessionDisplay.typeImageAsset("mystery"))
    }

    // MARK: - Type System Icon

    func testTypeIconKnownTypes() {
        XCTAssertEqual(SessionDisplay.typeIcon("notebook"), "book.pages")
        XCTAssertEqual(SessionDisplay.typeIcon("desktop"), "desktopcomputer")
        XCTAssertEqual(SessionDisplay.typeIcon("carta"), "map")
        XCTAssertEqual(SessionDisplay.typeIcon("contributed"), "shippingbox")
        XCTAssertEqual(SessionDisplay.typeIcon("firefly"), "flame")
    }

    func testTypeIconIsCaseInsensitive() {
        XCTAssertEqual(SessionDisplay.typeIcon("FIREFLY"), "flame")
    }

    func testTypeIconUnknownDefaultsToQuestionMark() {
        XCTAssertEqual(SessionDisplay.typeIcon("mystery"), "questionmark.square")
    }

    // MARK: - Time Formatting

    func testFormatTimeParsesFractionalSeconds() {
        // Valid ISO8601 WITH fractional seconds — first parse attempt.
        let formatted = SessionDisplay.formatTime("2024-03-15T10:30:45.123Z")
        XCTAssertNotEqual(formatted, "2024-03-15T10:30:45.123Z",
                          "Fractional-seconds timestamp should be reformatted, not echoed raw")
        XCTAssertFalse(formatted.isEmpty)
    }

    func testFormatTimeParsesWithoutFractionalSeconds() {
        // Valid ISO8601 WITHOUT fractional seconds — falls through to the
        // second parse attempt with only `.withInternetDateTime`.
        let formatted = SessionDisplay.formatTime("2024-03-15T10:30:45Z")
        XCTAssertNotEqual(formatted, "2024-03-15T10:30:45Z",
                          "Plain internet-date-time should be reformatted via fallback")
        XCTAssertFalse(formatted.isEmpty)
    }

    func testFormatTimeMalformedReturnsRawUnchanged() {
        XCTAssertEqual(SessionDisplay.formatTime("not-a-date"), "not-a-date")
        XCTAssertEqual(SessionDisplay.formatTime(""), "")
    }

    func testFormatTimeBothParsePathsAgreeForSameInstant() {
        // Same wall-clock instant expressed with and without the .000 fraction
        // must render identically through the display formatter.
        let withFraction = SessionDisplay.formatTime("2024-03-15T10:30:45.000Z")
        let withoutFraction = SessionDisplay.formatTime("2024-03-15T10:30:45Z")
        XCTAssertEqual(withFraction, withoutFraction)
    }

    // MARK: - Short Image Label

    func testShortImageLabelTakesLastPathComponent() {
        XCTAssertEqual(
            SessionDisplay.shortImageLabel("images.canfar.net/skaha/notebook:1.2.3"),
            "notebook:1.2.3")
    }

    func testShortImageLabelNoSlashReturnsWhole() {
        XCTAssertEqual(SessionDisplay.shortImageLabel("bare-image"), "bare-image")
    }
}
