// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 009: AgentsService.navigationTarget(forKind:) must route the
/// bulk/text variants the same way as their single counterparts so auto-apply
/// follow-on navigation is consistent.
@MainActor
final class NavigationTargetTests: XCTestCase {

    func testBulkAndTextVariantsRouteLikeSingles() {
        XCTAssertEqual(AgentsService.navigationTarget(forKind: "delete_sessions_bulk"), .portal)
        XCTAssertEqual(AgentsService.navigationTarget(forKind: "upload_text_to_vospace"), .storage)
    }

    func testSingleCounterpartsUnchanged() {
        XCTAssertEqual(AgentsService.navigationTarget(forKind: "delete_session"), .portal)
        XCTAssertEqual(AgentsService.navigationTarget(forKind: "upload_to_vospace"), .storage)
        XCTAssertEqual(AgentsService.navigationTarget(forKind: "save_query"), .search)
        XCTAssertEqual(AgentsService.navigationTarget(forKind: "download_observation"), .research)
    }

    func testUnknownKindHasNoTarget() {
        XCTAssertNil(AgentsService.navigationTarget(forKind: "totally_unknown_tool"))
    }
}
