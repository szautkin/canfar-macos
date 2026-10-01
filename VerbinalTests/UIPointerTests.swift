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
    /// "CFHT" means the collection named CFHT, not CFHTMEGAPIPE: a name's
    /// leading part is a stronger answer than words it contains.
    func testANamesLeadingPartIsWhatAPersonSays() {
        let collections: [UIPointerMatcher.Target] = [
            .init(id: "research/disclosure/CFHT, 15 items, expanded", label: "CFHT, 15 items, expanded", screen: "research"),
            .init(id: "research/disclosure/CFHTMEGAPIPE, 1 items, expanded", label: "CFHTMEGAPIPE, 1 items, expanded", screen: "research"),
        ]
        XCTAssertEqual(UIPointerMatcher.best(collections, for: "CFHT")?.label, "CFHT, 15 items, expanded")
        XCTAssertEqual(UIPointerMatcher.lead("Relaunch notebook1, astroml:latest"), "Relaunch notebook1")
        XCTAssertEqual(UIPointerMatcher.lead("M101 · CFHT — Sep 30"), "M101")
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
    /// pointed at, by session id, and say whose they are.
    func testASessionCardsActionsArePointable() async throws {
        try await AXReadable.require()
        let session = Session.compute(id: "q9p87ajc", status: "Running", name: "qa-person", type: "notebook")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SessionCardView(session: session, onOpen: {}, onDelete: {},
                                                                     onRenew: {}, onEvents: {}))
        window.orderFrontRegardless()
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "portal" })
        await source.ready()
        var named: [String: String?] = [:]
        for _ in 0..<25 where named["portal.session.q9p87ajc.delete"] == nil {
            let snapshot = source.snapshot()
            named = Dictionary(snapshot.elements.filter(\.stable).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(named["portal.session.q9p87ajc.delete"], "Delete qa-person")
        XCTAssertEqual(named["portal.session.q9p87ajc.renew"], "Renew qa-person")
    }
}
