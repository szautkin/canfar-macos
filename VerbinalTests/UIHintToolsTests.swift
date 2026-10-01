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

/// Plan 27 T: the tools an assistant points with — list_ui_targets,
/// point_at_ui, show_ui_hints, clear_ui_hints — on the app's own Search.
@MainActor
final class UIHintToolsTests: XCTestCase {

    private var window: NSWindow?
    private var state: AppState?

    override func tearDown() async throws {
        state?.uiHints.clearAll()
        window?.close()
        window = nil
        state = nil
    }

    private func search() async throws -> AppState {
        try await AXReadable.require()
        let state = AppState()
        state.currentMode = .search
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().uiWindowPlace(.main).environment(state))
        window.orderFrontRegardless()
        self.window = window
        self.state = state
        await state.uiHintPresenter.ready()
        try await Task.sleep(for: .milliseconds(500))
        return state
    }

    private let context = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                         budget: ProposalBudget())

    private func call<T: AITool>(_ tool: T, _ json: String) async throws -> [String: Any] {
        guard case .data(let data) = await tool.invoke(arguments: Data(json.utf8), context: context) else {
            XCTFail("\(T.self) failed")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testListingNamesEveryControlInTheWindowInFront() async throws {
        let state = try await search()
        let listed = try await call(state.makeListUITargetsTool(), "{}")
        XCTAssertEqual((listed["window"] as? [String: Any])?["screen"] as? String, "search")
        let targets = try XCTUnwrap(listed["targets"] as? [[String: Any]])
        XCTAssertGreaterThan(targets.count, 40, "every control, not a hand-picked few")
        let ids = Set(targets.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.isSuperset(of: ["search.run", "search.reset", "agent.pending"]))
        XCTAssertEqual(listed["unnamed"] as? Int, 0)
        let run = try XCTUnwrap(targets.first { $0["id"] as? String == "search.run" })
        XCTAssertEqual(run["stable"] as? Bool, true)
        XCTAssertEqual(run["kind"] as? String, "button")
        XCTAssertEqual((run["at"] as? [Int])?.count, 4)

        let page = try await call(state.makeListUITargetsTool(), #"{"limit":10}"#)
        XCTAssertEqual((page["targets"] as? [Any])?.count, 10)
        XCTAssertEqual(page["next"] as? String, "10")
        let all = try await call(state.makeListUITargetsTool(), #"{"kind":"all"}"#)
        XCTAssertGreaterThan(all["count"] as? Int ?? 0, listed["count"] as? Int ?? 0, "text and areas too")
    }

    func testPointingAddsAHintAndAMissSaysWhatThereIs() async throws {
        let state = try await search()
        let pointed = try await call(state.makePointAtUITool(), #"{"target":"search.run","message":"Runs the search."}"#)
        XCTAssertEqual(pointed["pointed"] as? Bool, true)
        XCTAssertEqual(pointed["as"] as? String, "bubble")
        _ = try await call(state.makePointAtUITool(), #"{"target":"Reset","message":"Clears the form."}"#)
        XCTAssertEqual(Set(state.uiHints.hints.map(\.id)), ["search.run", "search.reset"], "each call adds")

        // With hints up, the screen is still the screen: their overlay shares
        // the window's frame and must never read as it (the running app's QA
        // pass found the bubbles listed as the controls).
        try await Task.sleep(for: .milliseconds(200))
        let listed = try await call(state.makeListUITargetsTool(), "{}")
        XCTAssertGreaterThan(listed["count"] as? Int ?? 0, 40)
        let names = Set((listed["targets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        XCTAssertFalse(names.contains("Runs the search."), "a bubble is not a control")

        let missed = try await call(state.makePointAtUITool(), #"{"target":"no such thing anywhere"}"#)
        XCTAssertEqual(missed["pointed"] as? Bool, false)
        XCTAssertFalse((missed["candidates"] as? [Any] ?? []).isEmpty)
    }

    func testManyHintsAtOnceAndAllTheControlsRinged() async throws {
        let state = try await search()
        let shown = try await call(state.makeShowUIHintsTool(), #"""
        {"hints":[{"target":"search.run","text":"Runs it.","title":"Search"},
                  {"target":"search.reset","text":"Clears it."},
                  {"target":"nothing like this at all"}],
         "numbered":true,"mode":"replace"}
        """#)
        let set = try XCTUnwrap(shown["set"] as? String)
        let items = try XCTUnwrap(shown["shown"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["number"] as? Int }, [1, 2])
        XCTAssertEqual((shown["missing"] as? [[String: Any]])?.first?["target"] as? String, "nothing like this at all")

        let map = try await call(state.makeShowUIHintsTool(), #"{"all":{},"mode":"replace"}"#)
        let rings = try XCTUnwrap(map["shown"] as? [[String: Any]])
        XCTAssertGreaterThan(rings.count, 40)
        XCTAssertTrue(rings.allSatisfy { $0["as"] as? String == "ring" })
        XCTAssertTrue(state.uiHints.hints(in: set).isEmpty, "replace cleared the first set")

        let view = state.snapshotCurrentView()
        XCTAssertEqual(view.screen, "search")
        XCTAssertEqual(view.hints.first?.hints.count, rings.count)

        let cleared = try await call(state.makeClearUIHintsTool(), "{}")
        XCTAssertEqual(cleared["cleared"] as? Int, rings.count)
        XCTAssertTrue(state.uiHints.isEmpty)
    }

    /// A panel the person hid opens by its name — by app state, never by
    /// pressing its toggle — and closes again.
    func testAPanelOpensByItsName() async throws {
        let state = AppState()
        XCTAssertFalse(state.fileBrowserShown)
        let opened = try await call(state.makeOpenUITool(), #"{"target":"file browser"}"#)
        XCTAssertEqual(opened["done"] as? Bool, true)
        XCTAssertEqual(opened["id"] as? String, "panel.fileBrowser")
        XCTAssertTrue(state.fileBrowserShown)
        let again = try await call(state.makeOpenUITool(), #"{"target":"Show file browser"}"#)
        XCTAssertEqual(again["message"] as? String, "File browser was already shown")
        _ = try await call(state.makeCloseUITool(), #"{"target":"panel.fileBrowser"}"#)
        XCTAssertFalse(state.fileBrowserShown)
    }

    /// A tab is navigated to, never opened.
    func testATabIsNotOpened() async throws {
        let state = try await search()
        let refused = try await call(state.makeOpenUITool(), #"{"target":"ADQL"}"#)
        XCTAssertEqual(refused["done"] as? Bool, false)
        XCTAssertTrue((refused["message"] as? String)?.contains("navigated to") == true, "\(refused)")
    }

    /// The last hint of a set gone: list_events says so, and how.
    func testADismissedSetIsInTheEvents() async throws {
        let state = try await search()
        _ = try await call(state.makePointAtUITool(), #"{"target":"search.run","message":"Here."}"#)
        state.uiHints.clearAll(.closed)
        try await Task.sleep(for: .milliseconds(200))
        let entries = await state.agentsService.eventLog.entries(since: 0).entries
        guard case .hintsDismissed(_, let how) = entries.last?.event else { return XCTFail("\(entries)") }
        XCTAssertEqual(how, "closed")
    }
}
