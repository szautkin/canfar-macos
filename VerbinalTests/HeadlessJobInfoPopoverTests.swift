// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Coverage for `HeadlessJobInfoPopover`'s formatting helpers and
/// for the `HeadlessMonitorModel.deletingJobIDs` set used by the
/// row's in-flight indicator.
///
/// 2026-05-19 addition: the popover replaces right-click as the
/// primary "show job details" affordance. Pinning the formatters
/// here so a future format-string change doesn't silently break
/// what users see when they click the info icon.
final class HeadlessJobInfoPopoverTests: XCTestCase {

    // MARK: - CPU formatting

    func testFormatCPUEmptyIsEnDash() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatCPU(""), "—")
    }

    func testFormatCPUSingleIsSingular() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatCPU("1"), "1 core")
    }

    func testFormatCPUMultipleIsPlural() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatCPU("4"), "4 cores")
    }

    // MARK: - Memory formatting

    func testFormatMemoryEmptyIsEnDash() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory(""), "—")
    }

    func testFormatMemoryPassesThroughKubernetesUnit() {
        // Skaha returns memory with the K8s suffix ("4Gi", "512Mi").
        // Integer prefixes round-trip unchanged.
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("4Gi"), "4Gi")
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("512Mi"), "512Mi")
    }

    /// 2026-05-19 user-reported: Skaha echoes a clean `ram=1`
    /// request back as `"1.07Gi"` (1 GiB binary ≈ 1.073 GB
    /// decimal — the precision noise leaks through K8s's unit
    /// conversion). The user asked for 1; they should see 1.
    func testFormatMemoryRoundsNoisyFractionalGigabytes() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("1.07Gi"), "1Gi",
                       "user-requested 1 GB must surface as 1Gi, not 1.07Gi")
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("4.29Gi"), "4Gi")
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("8.59Gi"), "9Gi",
                       "rounds to nearest integer, not floor")
    }

    func testFormatMemoryPlainNumberRoundsToInt() {
        // Some Skaha responses omit the suffix entirely.
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("1.07"), "1")
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("1"), "1")
    }

    func testFormatMemoryUnparseablePassesThrough() {
        // Defensive: if Skaha returns something we don't
        // recognise, echo the raw string rather than silently
        // dropping the field.
        XCTAssertEqual(HeadlessJobInfoPopover.formatMemory("weird-format"), "weird-format")
    }

    // MARK: - GPU formatting

    func testFormatGPUEmptyIsNone() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatGPU(""), "None")
    }

    func testFormatGPUZeroIsNone() {
        // "0" must not appear in the UI — agents that don't pass
        // a GPU still get the value as "0" from Skaha, and
        // showing "0 GPUs" reads as "the system tried to give me
        // zero, why?" — "None" is the correct semantic.
        XCTAssertEqual(HeadlessJobInfoPopover.formatGPU("0"), "None")
    }

    func testFormatGPUSingleIsSingular() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatGPU("1"), "1 GPU")
    }

    func testFormatGPUMultipleIsPlural() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatGPU("2"), "2 GPUs")
    }

    // MARK: - Timestamp formatting

    func testFormatTimeEmptyIsEnDash() {
        XCTAssertEqual(HeadlessJobInfoPopover.formatTime(""), "—")
    }

    func testFormatTimeParsesISO8601() {
        // 2026-05-19T15:30:00Z → "May 19, 2026 HH:MM" in the
        // tester's local time zone. We can't pin the exact hour
        // (CDT = "10:30", JST = "00:30", UTC = "15:30") so we
        // assert the date stays + a colon-separated time renders.
        let result = HeadlessJobInfoPopover.formatTime("2026-05-19T15:30:00Z")
        XCTAssertTrue(result.contains("May 19, 2026"),
                      "must include the date; got '\(result)'")
        // Loose match for a HH:MM time component.
        let timeRegex = #/\d{1,2}:\d{2}/#
        XCTAssertNotNil(try? timeRegex.firstMatch(in: result),
                        "must include a HH:MM time; got '\(result)'")
    }

    func testFormatTimeParsesFractionalSeconds() {
        // Skaha sometimes returns timestamps with ms precision.
        // The formatter should accept both shapes.
        let result = HeadlessJobInfoPopover.formatTime("2026-05-19T15:30:00.123Z")
        XCTAssertTrue(result.contains("May 19, 2026"),
                      "must accept fractional seconds; got '\(result)'")
    }

    func testFormatTimeUnparseableEchoesRaw() {
        // Defensive: if Skaha changes its format we'd rather show
        // the raw string than silently drop the field. The user
        // sees "weird-format-here" and can file a bug.
        let weird = "not-a-timestamp"
        XCTAssertEqual(HeadlessJobInfoPopover.formatTime(weird), weird)
    }

    // MARK: - Model: deletingJobIDs set

    /// Starts empty — the row's delete button reads this on every
    /// render; a stale entry would surface a phantom "delete in
    /// progress" indicator for a job not actually being deleted.
    @MainActor
    func testDeletingJobIDsStartsEmpty() {
        // We construct a model without making a real network
        // call by passing a service with a dummy NetworkClient.
        // The set is exposed independent of any service work,
        // so this is purely a state-on-init pin.
        let net = NetworkClient(session: .shared)
        let svc = HeadlessService(network: net)
        let model = HeadlessMonitorModel(headlessService: svc)
        XCTAssertTrue(model.deletingJobIDs.isEmpty,
                      "row should never show in-flight indicator on app start")
    }
}
