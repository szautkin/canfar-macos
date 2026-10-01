// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 27 O: the hints that are up, how long they stay, and how they go.
@MainActor
final class UIHintStoreTests: XCTestCase {

    private func hint(_ id: String, window: Int = 1, style: UIHint.Style = .bubble,
                      frame: CGRect = CGRect(x: 10, y: 10, width: 80, height: 24)) -> UIHint {
        UIHint(id: id, set: "", style: style, title: nil, text: "Press \(id)", number: nil, frame: frame,
               kind: .button, screen: "search", window: window)
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [UIHintStore.Dismissed] = []
        func add(_ d: UIHintStore.Dismissed) { lock.withLock { list.append(d) } }
        var all: [UIHintStore.Dismissed] { lock.withLock { list } }
    }

    func testASetIsShownNumberedAndTheSameElementReplacesItsHint() {
        let store = UIHintStore()
        let first = store.show([hint("a"), hint("b")], numbered: true, dim: false, seconds: 8, replace: false)
        XCTAssertEqual(store.hints.map(\.number), [1, 2])
        XCTAssertEqual(store.hints.map(\.set), [first, first])
        let second = store.show([hint("b")], numbered: false, dim: false, seconds: 8, replace: false)
        XCTAssertEqual(store.hints.map(\.id), ["a", "b"], "b replaced, never stacked")
        XCTAssertEqual(store.hints.last?.set, second)
        _ = store.show([hint("c")], numbered: false, dim: false, seconds: 8, replace: true)
        XCTAssertEqual(store.hints.map(\.id), ["c"])
    }

    func testHintsGoWhenTheirTimeIsUpButNotWhileTheyAreRead() {
        let store = UIHintStore()
        let t0 = Date()
        _ = store.show([hint("a"), hint("b")], numbered: false, dim: false, seconds: 5, replace: false, now: t0)
        store.pause("a", now: t0.addingTimeInterval(2))
        store.expire(now: t0.addingTimeInterval(6))
        XCTAssertEqual(store.hints.map(\.id), ["a"], "b timed out; a is being read")
        store.resume("a", now: t0.addingTimeInterval(20))
        store.expire(now: t0.addingTimeInterval(22))
        XCTAssertEqual(store.hints.map(\.id), ["a"], "three seconds were left when the person started reading")
        store.expire(now: t0.addingTimeInterval(23.5))
        XCTAssertTrue(store.isEmpty)
    }

    func testUntilClosedWaitsForThePerson() {
        let store = UIHintStore()
        let t0 = Date()
        _ = store.show([hint("a")], numbered: false, dim: false,
                       seconds: UIHintStore.seconds(asked: nil, untilClosed: true, bubbles: true), replace: false, now: t0)
        store.expire(now: t0.addingTimeInterval(3_600))
        XCTAssertEqual(store.hints.count, 1)
        store.close("a")
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(UIHintStore.seconds(asked: 500, untilClosed: false, bubbles: true), 120, "at most two minutes")
        XCTAssertEqual(UIHintStore.seconds(asked: nil, untilClosed: false, bubbles: false), 15, "rings stay longer")
    }

    /// The assistant learns when the person is done: once per set, as its
    /// last hint goes, and how.
    func testASetIsDismissedOnceWhenItsLastHintGoes() {
        let store = UIHintStore()
        let heard = Heard()
        _ = store.dismissed.observe { heard.add($0) }
        let set = store.show([hint("a"), hint("b")], numbered: false, dim: false, seconds: nil, replace: false)
        store.close("a")
        XCTAssertTrue(heard.all.isEmpty)
        store.close("b")
        XCTAssertEqual(heard.all, [.init(set: set, how: .closed)])
        let other = store.show([hint("c", window: 7)], numbered: false, dim: false, seconds: nil, replace: false)
        store.clear(window: 7, .screenChanged)
        XCTAssertEqual(heard.all.last, .init(set: other, how: .screenChanged))
    }

    func testHintsFollowTheirElementsAndGoWithThem() {
        let store = UIHintStore()
        _ = store.show([hint("a"), hint("b")], numbered: false, dim: false, seconds: nil, replace: false)
        store.move(["a": (CGRect(x: 10, y: 200, width: 80, height: 24), 1)], gone: ["b"])
        XCTAssertEqual(store.hints.map(\.id), ["a"])
        XCTAssertEqual(store.hints.first?.frame.minY, 200)
    }
}

/// Plan 27 O: one window's scene, from its hints and the layout.
@MainActor
final class UIHintSceneTests: XCTestCase {

    private struct FixedMeasure: UIHintMeasuring {
        func bubble(title: String?, text: String?, numbered: Bool) -> CGSize { CGSize(width: 200, height: 50) }
        func list(_ entries: [UIHintScene.Entry], maxHeight: CGFloat) -> CGSize {
            CGSize(width: 260, height: min(maxHeight, 30 + CGFloat(entries.count) * 30))
        }
    }

    private func hint(_ id: String, _ frame: CGRect, kind: UIElementKind = .button, style: UIHint.Style = .bubble,
                      number: Int? = nil) -> UIHint {
        UIHint(id: id, set: "s1", style: style, title: nil, text: style == .bubble ? "about \(id)" : nil, number: number,
               frame: frame, kind: kind, screen: "search", window: 1)
    }

    private let size = CGSize(width: 1200, height: 800)

    func testEveryHintHasARingAndBubblesNeverOverlap() {
        let hints = (0..<6).map { hint("h\($0)", CGRect(x: 100 + CGFloat($0) * 150, y: 300, width: 80, height: 24)) }
        let scene = UIHintScene.build(hints: hints, sets: ["s1": .init(id: "s1", numbered: false, dim: true, seconds: nil)],
                                      size: size, controls: [], images: [], previous: [:], measure: FixedMeasure())
        XCTAssertEqual(scene.rings.count, 6)
        XCTAssertEqual(scene.bubbles.count, 6)
        XCTAssertTrue(scene.dim)
        for (i, a) in scene.bubbles.enumerated() {
            for b in scene.bubbles[(i + 1)...] { XCTAssertFalse(a.frame.intersects(b.frame)) }
            for ring in scene.rings { XCTAssertFalse(ring.frame.intersects(a.frame)) }
        }
    }

    func testRingsAloneHaveNoBubblesAndAnAreaHoldingOthersIsDashed() {
        let area = hint("search.spatial", CGRect(x: 100, y: 100, width: 400, height: 300), kind: .area, style: .ring)
        let inside = hint("search.target", CGRect(x: 120, y: 140, width: 200, height: 24), style: .ring)
        let scene = UIHintScene.build(hints: [area, inside], sets: [:], size: size, controls: [], images: [],
                                      previous: [:], measure: FixedMeasure())
        XCTAssertTrue(scene.bubbles.isEmpty)
        XCTAssertEqual(scene.rings.first { $0.id == "search.spatial" }?.dashed, true)
        XCTAssertEqual(scene.rings.first { $0.id == "search.target" }?.dashed, false)
    }

    /// Past twelve, the words go to the hint list, each element badged with
    /// its number — the set's own numbers when it is numbered.
    func testPastTwelveTheWordsGoToTheListWithBadges() {
        let hints = (0..<16).map { i in
            hint("h\(i)", CGRect(x: 30 + CGFloat(i % 4) * 280, y: 40 + CGFloat(i / 4) * 180, width: 60, height: 20), number: i + 1)
        }
        let scene = UIHintScene.build(hints: hints, sets: [:], size: size, controls: [], images: [],
                                      previous: [:], measure: FixedMeasure())
        XCTAssertEqual(scene.bubbles.count, 12)
        XCTAssertEqual(scene.entries.map(\.number), [13, 14, 15, 16])
        XCTAssertEqual(Set(scene.badges.map(\.id)), Set(scene.entries.map(\.id)))
        let list = try! XCTUnwrap(scene.listFrame)
        for ring in scene.rings { XCTAssertFalse(ring.frame.intersects(list)) }
        XCTAssertNil(scene.pillFrame)
    }
}
