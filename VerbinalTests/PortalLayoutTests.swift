// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Where the Portal's cards go, wide and narrow, and the launch form an agent opens.
@MainActor
final class PortalLayoutTests: XCTestCase {

    func testEveryCardHasAPlaceInsideTheGridAndNoTwoOverlap() {
        for arrangement in [PortalLayout.wide, PortalLayout.narrow] {
            XCTAssertEqual(Set(arrangement.keys), Set(PortalCard.allCases))
            var taken = Set<[Int]>()
            for (card, cell) in arrangement {
                XCTAssertTrue((0..<PortalLayout.columns).contains(cell.column))
                XCTAssertLessThanOrEqual(cell.column + cell.span, PortalLayout.columns)
                for column in cell.column..<(cell.column + cell.span) {
                    XCTAssertTrue(taken.insert([cell.row, column]).inserted, "\(card) overlaps at \(cell.row), \(column)")
                }
            }
        }
    }

    func testWideIsStatusCardsThenSessionsThenImagesBesideRecentLaunches() {
        let rows = PortalLayout.rows(PortalLayout.wide).map { $0.map(\.card) }
        XCTAssertEqual(rows, [[.platformLoad, .storage, .batchJobs], [.sessions], [.images, .recentLaunches]])
        XCTAssertEqual(PortalLayout.wide[.sessions]?.span, 3)
        XCTAssertEqual(PortalLayout.wide[.images]?.span, 2)
    }

    func testNarrowIsOneColumnInTheSameOrderBelowTheBreakpoint() {
        XCTAssertEqual(PortalLayout.rows(PortalLayout.narrow).map { $0.map(\.card) }, PortalCard.allCases.map { [$0] })
        XCTAssertEqual(PortalLayout.arrangement(forWidth: 999.9), PortalLayout.narrow)
        XCTAssertEqual(PortalLayout.arrangement(forWidth: 1000), PortalLayout.wide)
    }

    // MARK: - show_launch_form

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
    }

    func testTheLaunchFormClosesAndIsOnlyOpenedForSomeoneSignedIn() async throws {
        let state = AppState(marks: MarkStore(persistence: nil))
        state.launchFormPresented = true
        let closed = await state.makeShowLaunchFormTool().invoke(arguments: Data(#"{"close":true}"#.utf8), context: ctx())
        guard case .data = closed else { return XCTFail("\(closed)") }
        XCTAssertFalse(state.launchFormPresented)

        if !state.isAuthenticated {
            let refused = await state.makeShowLaunchFormTool().invoke(arguments: Data(#"{"tab":"advanced"}"#.utf8), context: ctx())
            guard case .failed(.targetNotResolved) = refused else { return XCTFail("\(refused)") }
            XCTAssertNil(state.launchFormRequest)
        }
        let badTab = await state.makeShowLaunchFormTool().invoke(arguments: Data(#"{"tab":"gpu"}"#.utf8), context: ctx())
        guard case .failed(.invalidArgument) = badTab else { return XCTFail("\(badTab)") }
    }
}
