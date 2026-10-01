// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import XCTest
@testable import VerbinalKit

/// Plan 27 Y: where hints' bubbles go — no overlaps, by rules, the same way
/// every time.
final class UIHintLayoutTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    /// A seeded generator, so a failing screen can be replayed.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// A screen of controls, some hinted, none overlapping.
    private func screen(seed: UInt64, hinted: Int, controls: Int = 40) -> UIHintLayout.Input {
        var rng = Seeded(state: seed)
        var rects: [CGRect] = []
        while rects.count < hinted + controls {
            let w = CGFloat.random(in: 24...220, using: &rng), h = CGFloat.random(in: 16...40, using: &rng)
            let r = CGRect(x: CGFloat.random(in: 0...(1200 - w), using: &rng),
                           y: CGFloat.random(in: 0...(800 - h), using: &rng), width: w, height: h)
            if !rects.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) }) { rects.append(r) }
        }
        let hints = rects.prefix(hinted).enumerated().map { index, rect in
            UIHintLayout.Hint(id: "h\(index)", target: rect,
                              bubble: CGSize(width: CGFloat.random(in: 160...300, using: &rng),
                                             height: CGFloat.random(in: 30...90, using: &rng)))
        }
        return .init(bounds: bounds, hints: hints, controls: Array(rects.dropFirst(hinted)))
    }

    // MARK: - The hard rules, on 200 screens

    func testTheHardRulesHoldOnEveryScreen() {
        for seed in 1...200 as ClosedRange<UInt64> {
            let input = screen(seed: seed, hinted: Int(seed % 20) + 1)
            let placement = UIHintLayout.place(input)
            let bubbles = Array(placement.bubbles.values)
            for (i, a) in bubbles.enumerated() {
                XCTAssertTrue(bounds.contains(a.frame), "seed \(seed): inside the window")
                for hint in input.hints {
                    XCTAssertFalse(hint.target.intersects(a.frame), "seed \(seed): covers \(hint.id)")
                }
                for b in bubbles[(i + 1)...] {
                    XCTAssertFalse(a.frame.insetBy(dx: -UIHintLayout.gap / 2, dy: -UIHintLayout.gap / 2)
                        .intersects(b.frame.insetBy(dx: -UIHintLayout.gap / 2, dy: -UIHintLayout.gap / 2)),
                                   "seed \(seed): two bubbles overlap")
                }
            }
            XCTAssertLessThanOrEqual(bubbles.count, UIHintLayout.maxBubbles)
            let shown = Set(placement.bubbles.keys), listed = Set(placement.listed)
            XCTAssertTrue(shown.isDisjoint(with: listed), "seed \(seed)")
            XCTAssertEqual(shown.union(listed), Set(input.hints.map(\.id)), "seed \(seed): every hint somewhere")
            XCTAssertEqual(UIHintLayout.place(input), placement, "seed \(seed): the same every time")
        }
    }

    func testBadgesNeverOverlapOrCoverAnotherHint() {
        for seed in 1...100 as ClosedRange<UInt64> {
            let input = screen(seed: seed, hinted: 20, controls: 10)
            let placement = UIHintLayout.place(input)
            let badges = Array(placement.badges)
            XCTAssertEqual(Set(placement.badges.keys), Set(placement.listed))
            for (i, a) in badges.enumerated() {
                for b in badges[(i + 1)...] { XCTAssertFalse(a.value.intersects(b.value), "seed \(seed)") }
                for hint in input.hints where hint.id != a.key {
                    XCTAssertFalse(hint.target.intersects(a.value), "seed \(seed): \(a.key)'s badge on \(hint.id)")
                }
            }
        }
    }

    // MARK: - The preferences

    func testALoneControlGetsItsBubbleBelowWithATail() {
        let target = CGRect(x: 500, y: 100, width: 80, height: 24)
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "run", target: target, bubble: CGSize(width: 200, height: 50)),
        ]))
        let bubble = try! XCTUnwrap(placement.bubbles["run"])
        XCTAssertEqual(bubble.side, .below)
        XCTAssertFalse(bubble.line)
        XCTAssertEqual(bubble.frame.midX, target.midX, "centred")
        XCTAssertEqual(bubble.anchor.y, target.maxY)
    }

    func testNearTheBottomTheBubbleGoesWhereThereIsRoom() {
        let target = CGRect(x: 500, y: 760, width: 80, height: 24)
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "bar", target: target, bubble: CGSize(width: 200, height: 50)),
        ]))
        XCTAssertEqual(placement.bubbles["bar"]?.side, .above)
    }

    /// A bubble keeps off an image — its marks stay in sight — when there is
    /// room elsewhere, even room it likes less.
    func testABubbleKeepsOffAnImage() {
        let image = CGRect(x: 300, y: 130, width: 800, height: 600)
        let target = CGRect(x: 300, y: 100, width: 80, height: 24)
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "stretch", target: target, bubble: CGSize(width: 200, height: 50)),
        ], images: [image]))
        let bubble = try! XCTUnwrap(placement.bubbles["stretch"])
        XCTAssertFalse(bubble.frame.intersects(image), "\(bubble)")
    }

    /// Other controls are covered only when there is no empty space.
    func testABubblePrefersEmptySpaceOverControls() {
        let target = CGRect(x: 500, y: 100, width: 80, height: 24)
        let below = CGRect(x: 380, y: 130, width: 320, height: 200)
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "run", target: target, bubble: CGSize(width: 200, height: 50)),
        ], controls: [below]))
        let bubble = try! XCTUnwrap(placement.bubbles["run"])
        XCTAssertFalse(bubble.frame.intersects(below), "\(bubble)")
    }

    /// The hint with the fewest spots goes first: a control boxed in on three
    /// sides keeps its one open side, though another hint came first.
    func testTheMostConstrainedHintIsPlacedFirst() {
        let boxed = CGRect(x: 1100, y: 0, width: 100, height: 30)        // top-right corner: only below, or left
        let wall = CGRect(x: 880, y: 0, width: 210, height: 30)          // its left neighbour, hinted too
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "wall", target: wall, bubble: CGSize(width: 220, height: 60)),
            .init(id: "boxed", target: boxed, bubble: CGSize(width: 220, height: 60)),
        ]))
        XCTAssertNotNil(placement.bubbles["boxed"])
        XCTAssertNotNil(placement.bubbles["wall"])
        XCTAssertTrue(placement.listed.isEmpty)
    }

    func testPastTwelveTheRestGoToTheListInTheOrderGiven() {
        let hints = (0..<20).map { i in
            UIHintLayout.Hint(id: "h\(i)", target: CGRect(x: 20 + CGFloat(i % 5) * 230, y: 20 + CGFloat(i / 5) * 190,
                                                            width: 60, height: 20),
                              bubble: CGSize(width: 150, height: 40))
        }
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: hints))
        XCTAssertEqual(placement.bubbles.count, 12)
        XCTAssertEqual(placement.listed, (12..<20).map { "h\($0)" })
    }

    /// A scroll moves an element: its bubble keeps its place beside it.
    func testABubbleStaysBesideItsElementWhenItMoves() {
        let target = CGRect(x: 500, y: 300, width: 80, height: 24)
        let first = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "a", target: target, bubble: CGSize(width: 200, height: 50)),
        ], controls: [CGRect(x: 380, y: 330, width: 320, height: 200)]))
        let bubble = try! XCTUnwrap(first.bubbles["a"])
        let relative = bubble.frame.offsetBy(dx: -target.minX, dy: -target.minY)
        let moved = target.offsetBy(dx: 0, dy: -120)
        let second = UIHintLayout.place(.init(bounds: bounds, hints: [
            .init(id: "a", target: moved, bubble: CGSize(width: 200, height: 50), previous: relative),
        ]))
        XCTAssertEqual(second.bubbles["a"]?.frame, bubble.frame.offsetBy(dx: 0, dy: -120),
                       "kept, though below is free now")
    }

    // MARK: - The hint list

    func testTheListDocksClearOfTheHintsOrIsAPill() {
        let keepClear = [CGRect(x: 1000, y: 0, width: 200, height: 200)]
        let list = UIHintLayout.placeList(size: CGSize(width: 260, height: 300), in: bounds, keepClear: keepClear)
        let frame = try! XCTUnwrap(list)
        XCTAssertTrue(bounds.contains(frame))
        XCTAssertFalse(keepClear[0].intersects(frame))
        XCTAssertNil(UIHintLayout.placeList(size: CGSize(width: 2000, height: 300), in: bounds, keepClear: []),
                     "too big: a pill")
    }

    func testLinesCross() {
        XCTAssertTrue(UIHintLayout.segmentsCross(.init(x: 0, y: 0), .init(x: 10, y: 10), .init(x: 0, y: 10), .init(x: 10, y: 0)))
        XCTAssertFalse(UIHintLayout.segmentsCross(.init(x: 0, y: 0), .init(x: 10, y: 0), .init(x: 0, y: 5), .init(x: 10, y: 5)))
    }
}
