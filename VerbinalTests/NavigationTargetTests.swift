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

    /// Ticket 036: `clear_user_site` is intentionally excluded from the
    /// navigation table. It wipes user-site Python packages, which has no
    /// user-visible UI surface, so it must fall through to nil rather than
    /// route to Storage. This is a deliberate omission, not the missing-case
    /// defect fixed in ticket 009.
    func testClearUserSiteIntentionallyHasNoTarget() {
        // Allow-list of kinds that must stay nil on purpose. A future
        // reviewer adding follow-on navigation for one of these should
        // remove it from this list deliberately, not by accident.
        let intentionallyNilKinds = ["clear_user_site"]
        for kind in intentionallyNilKinds {
            XCTAssertNil(
                AgentsService.navigationTarget(forKind: kind),
                "\(kind) is intentionally omitted from navigationTarget and must remain nil"
            )
        }
    }
}
