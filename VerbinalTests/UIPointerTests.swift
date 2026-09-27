// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
}
