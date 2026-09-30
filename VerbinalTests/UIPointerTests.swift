// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
import VerbinalKit
@testable import Verbinal

/// point_at_ui lands on exactly one control or on none — never a guess.
@MainActor
final class UIPointerTests: XCTestCase {

    private let targets: [UIPointerMatcher.Target] = [
        .init(id: "settings.agent.allowExternal", label: "Allow external AI agents", screen: "settings.agent"),
        .init(id: "settings.agent.autoApply", label: "Auto-apply agent writes", screen: "settings.agent"),
        .init(id: "search.run", label: "Search", screen: "search"),
        .init(id: "adql.execute", label: "Execute", screen: "search.adql"),
    ]

    func testTheIdWinsThenTheLabelThenWords() {
        XCTAssertEqual(UIPointerMatcher.best(targets, for: "search.run")?.id, "search.run")
        XCTAssertEqual(UIPointerMatcher.best(targets, for: "auto-apply agent writes")?.id, "settings.agent.autoApply")
        XCTAssertEqual(UIPointerMatcher.best(targets, for: "external AI")?.id, "settings.agent.allowExternal")
    }

    /// "agent" is in two labels: a question, not an answer.
    /// A control shown in two places stays registered while either shows
    /// it — the new toolbar appears before the old one goes (plan 17 U1).
    @MainActor
    func testAControlInTwoPlacesStaysWhileOneShowsIt() {
        let registry = UIPointerRegistry()
        let robot = UIPointerMatcher.Target(id: "agent.pending", label: "Pending changes", screen: "window")
        registry.register(robot)      // the Portal's toolbar appears
        registry.register(robot)      // …the landing toolbar, before the Portal's goes
        registry.unregister(robot.id) // the Portal's goes
        XCTAssertNotNil(registry.targets[robot.id])
        registry.unregister(robot.id)
        XCTAssertNil(registry.targets[robot.id])
    }

    func testTwoEqualMatchesPointAtNothing() {
        XCTAssertNil(UIPointerMatcher.best(targets, for: "agent"))
        XCTAssertNil(UIPointerMatcher.best(targets, for: "nothing like this"))
        XCTAssertNil(UIPointerMatcher.best(targets, for: "   "))
    }

    func testAMissOffersTheNearestControlsFirst() {
        let offered = UIPointerMatcher.candidates(targets, for: "agent toggle")
        XCTAssertEqual(Set(offered.prefix(2).map(\.id)), ["settings.agent.allowExternal", "settings.agent.autoApply"])
    }

    func testPointingSetsAHintAndLeavingTheScreenClearsIt() {
        let registry = UIPointerRegistry()
        targets.forEach(registry.register)
        guard case .pointed(let target) = registry.point(at: "Execute", message: "Run it here", seconds: 30) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(target.id, "adql.execute")
        XCTAssertEqual(registry.hint?.targetID, "adql.execute")
        XCTAssertEqual(registry.hint?.message, "Run it here")
        registry.unregister("adql.execute")
        XCTAssertNil(registry.hint, "a hint does not outlive its control")
        guard case .notFound = registry.point(at: "Execute", message: nil, seconds: nil) else {
            return XCTFail("a control that left cannot be pointed at")
        }
    }

    func testOpenSettingsGoesToTheSectionAndCloseClosesIt() async {
        let state = AppState()
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let open = state.makeOpenSettingsTool()
        let bad = await open.invoke(arguments: Data(#"{"section":"nowhere"}"#.utf8), context: ctx)
        guard case .failed = bad else { return XCTFail("an unknown section must be refused by the schema") }

        let ok = await open.invoke(arguments: Data(#"{"section":"agent"}"#.utf8), context: ctx)
        guard case .data = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(state.settingsSection, .agent)
        XCTAssertEqual(state.settingsRequest?.action, .open)

        _ = await state.makeCloseSettingsTool().invoke(arguments: Data("{}".utf8), context: ctx)
        XCTAssertEqual(state.settingsRequest?.action, .close)
    }

    /// Plan 21 N2: each Portal session card's Renew and Delete can be
    /// pointed at, by session id — a pass could not point at them.
    func testASessionCardsActionsArePointable() async throws {
        let registry = UIPointerRegistry()
        let session = Session.compute(id: "q9p87ajc", status: "Running", name: "qa-person", type: "notebook")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SessionCardView(session: session, onOpen: {}, onDelete: {},
                                                                     onRenew: {}, onEvents: {})
            .environment(registry))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<100 where registry.targets["portal.session.q9p87ajc.delete"] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(registry.targets["portal.session.q9p87ajc.delete"]?.label, "Delete qa-person")
        XCTAssertEqual(registry.targets["portal.session.q9p87ajc.renew"]?.label, "Renew qa-person")
    }
}
