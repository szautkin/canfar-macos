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

    /// Cards share the width: equal columns, spacing between, a span its
    /// columns and the gaps inside it — never more than the width given.
    func testACardIsItsColumnsWidthAndTheCardsNeverExceedTheWidth() {
        let width: CGFloat = 1441
        let one = PortalLayout.width(ofSpan: 1, in: width)
        XCTAssertEqual(one * 3 + PortalLayout.spacing * 2, width, accuracy: 0.001)
        XCTAssertEqual(PortalLayout.width(ofSpan: 2, in: width), one * 2 + PortalLayout.spacing, accuracy: 0.001)
        XCTAssertEqual(PortalLayout.width(ofSpan: 3, in: width), width, accuracy: 0.001)
        XCTAssertEqual(PortalLayout.width(ofSpan: 9, in: width), width, accuracy: 0.001, "a span past the columns is all of them")
        XCTAssertEqual(PortalLayout.width(ofSpan: 1, in: 10), 0, "no negative width in a tiny window")
    }

    /// Batch jobs and images wait for sign-in: beside other cards their place
    /// is kept; alone in a row (narrow), the row goes.
    func testAnAbsentCardKeepsItsPlaceOnlyInARowOthersShare() {
        let present = Set(PortalCard.allCases).subtracting([.batchJobs, .images])
        let wide = PortalLayout.rows(PortalLayout.wide, present: present).map { $0.map(\.card) }
        XCTAssertEqual(wide, [[.platformLoad, .storage, .batchJobs], [.sessions], [.images, .recentLaunches]])
        let narrow = PortalLayout.rows(PortalLayout.narrow, present: present).map { $0.map(\.card) }
        XCTAssertEqual(narrow, [[.platformLoad], [.storage], [.sessions], [.recentLaunches]])
    }

    // MARK: - show_launch_form

    private struct NoLaunch: SessionLaunching {
        func launchSession(_ params: SessionLaunchParams) async throws -> String? { nil }
    }

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

    /// Plan 30 T5: the form's resources come with it — a size given is a
    /// fixed one, and only a size the form offers.
    func testTheLaunchFormTakesTheSizesItOffers() async throws {
        let state = AppState(marks: MarkStore(persistence: nil))
        state.auth.apply(username: "qa-person", userInfo: nil)
        let model = SessionLaunchModel(sessionService: NoLaunch(),
                                       imageService: ImageService(network: NetworkClient(session: .shared)),
                                       recentLaunchStore: RecentLaunchStore())
        model.coreOptions = [1, 2, 4]
        model.ramOptions = [4, 8, 16]
        model.gpuOptions = [0, 1]
        state.sessionLaunchModelForTools = model

        for refused in [#"{"cores":3}"#, #"{"ram":32}"#, #"{"gpus":2}"#, #"{"resources":"flexible","cores":2}"#] {
            let answer = await state.makeShowLaunchFormTool().invoke(arguments: Data(refused.utf8), context: ctx())
            guard case .failed(.invalidArgument) = answer else { return XCTFail("\(refused): \(answer)") }
            XCTAssertNil(state.launchFormRequest, refused)
        }

        let shown = await state.makeShowLaunchFormTool().invoke(arguments: Data(#"{"cores":4,"ram":16}"#.utf8), context: ctx())
        guard case .data = shown else { return XCTFail("\(shown)") }
        let request = try XCTUnwrap(state.launchFormRequest)
        XCTAssertEqual(request.resources, LaunchResources(cores: 4, ram: 16))
        model.apply(request.resources)
        XCTAssertEqual(model.resourceType, "fixed")
        XCTAssertEqual(model.cores, 4)
        XCTAssertEqual(model.ram, 16)

        model.apply(LaunchResources(type: "flexible"))
        XCTAssertEqual(model.resourceType, "flexible")
        XCTAssertEqual(model.cores, 4, "Flexible keeps the steppers as they were")
    }
}
