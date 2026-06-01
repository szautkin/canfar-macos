// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

/// Ticket 007: ToolFailureReason.description must bound the user/server-
/// supplied strings it interpolates (so overlong/noisy input can't bloat or
/// leak verbatim onto the MCP wire), while auditTag stays stable and free of
/// any interpolated input.
final class ToolFailureReasonTests: XCTestCase {

    private let huge = String(repeating: "A", count: 500)

    func testDescriptionTruncatesOverlongInput() {
        let cases: [ToolFailureReason] = [
            .invalidArgument(huge),
            .unknownTarget(huge),
            .targetNotResolved(huge),
            .unsupportedIdScheme(huge),
            .planePublisherIdNotSupported(huge),
            .backendError(huge),
        ]
        for reason in cases {
            let desc = reason.description
            XCTAssertTrue(desc.contains("… (truncated)"), "\(reason.auditTag) should truncate overlong input")
            // The raw 500-char run must not appear verbatim.
            XCTAssertFalse(desc.contains(huge), "\(reason.auditTag) leaked the full input")
        }
    }

    func testDescriptionLeavesShortInputIntact() {
        XCTAssertEqual(ToolFailureReason.unknownTarget("M31").description, "unknownTarget: M31")
        XCTAssertFalse(ToolFailureReason.backendError("timeout").description.contains("truncated"))
    }

    func testAuditTagNeverInterpolatesInput() {
        // Regression guard: the audit tag is a stable, PII-free token.
        XCTAssertEqual(ToolFailureReason.invalidArgument(huge).auditTag, "invalidArgument")
        XCTAssertEqual(ToolFailureReason.unknownTarget(huge).auditTag, "unknownTarget")
        XCTAssertEqual(ToolFailureReason.targetNotResolved(huge).auditTag, "targetNotResolved")
        XCTAssertEqual(ToolFailureReason.unsupportedIdScheme(huge).auditTag, "unsupportedIdScheme")
        XCTAssertEqual(ToolFailureReason.planePublisherIdNotSupported(huge).auditTag, "planePublisherIdNotSupported")
        XCTAssertEqual(ToolFailureReason.backendError(huge).auditTag, "backendError")
        for tag in [ToolFailureReason.authRequired.auditTag,
                    ToolFailureReason.perTurnProposalCapExceeded(limit: 8).auditTag,
                    ToolFailureReason.notImplemented.auditTag] {
            XCTAssertFalse(tag.contains("A"), "auditTag must not contain interpolated input")
        }
    }

    func testClipBoundary() {
        XCTAssertEqual(ToolFailureReason.clip("short", max: 10), "short")
        let exactly = String(repeating: "x", count: 10)
        XCTAssertEqual(ToolFailureReason.clip(exactly, max: 10), exactly, "at-limit input is not truncated")
        XCTAssertTrue(ToolFailureReason.clip(String(repeating: "x", count: 11), max: 10).hasSuffix("… (truncated)"))
    }
}
