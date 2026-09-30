// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 23 L7: a read tool never gives up on CADC before the request
/// would — its deadline follows the request timeouts — unless it has a
/// reason of its own, named here.
final class ToolDeadlineTests: XCTestCase {

    /// Stop early on purpose: get_data_links falls back to the CAOM-2
    /// inventory in time; a preview image is not worth a two-minute wait;
    /// the health probes take 15 s each, all at once.
    private static let reasoned: Set<String> = ["get_data_links", "get_preview_image", "get_service_health"]

    @MainActor
    func testEveryReadToolWaitsAtLeastAsLongAsItsRequests() {
        var checked = 0
        for tool in AppState().makeAgentTools() {
            guard let read = tool as? any JSONReadTool else { continue }
            checked += 1
            if Self.reasoned.contains(tool.name) {
                XCTAssertLessThan(read.toolTimeoutSeconds, RequestTimeout.standard, "\(tool.name) keeps its reason")
            } else {
                XCTAssertGreaterThan(read.toolTimeoutSeconds, RequestTimeout.standard,
                                     "\(tool.name) would stop before its request's own timeout")
            }
        }
        XCTAssertGreaterThan(checked, 60, "the read tools were not found")
    }

    func testTheDeadlineIsInsideTheRoutersCeiling() {
        XCTAssertEqual(RequestTimeout.toolDeadline, RequestTimeout.standard + 10)
        XCTAssertLessThan(RequestTimeout.toolDeadline, 150, "the router's read ceiling")
    }
}
