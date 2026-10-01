// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// Where each hint's bubble goes on a window — by stated rules, not by
/// guessing (plan 27 Y). It knows rectangles and sizes only: no window, no
/// view, no element. Hints point at the app's interface; they are not the
/// marks on an image.
///
/// **Hard rules** — a spot that breaks one is never used:
/// 1. bubbles never overlap each other (`gap` apart);
/// 2. a bubble never covers a hinted element, its own included;
/// 3. a bubble stays inside the window's visible content.
///
/// **Preferences**, as a cost, lowest wins: covering other controls costs by
/// the share covered, an image four times as much; the side with the most
/// room first (ties: below, right, above, left); centred over start or end;
/// near over slid along, over a second ring out with a line; a line that
/// crosses a bubble or another line costs more.
///
/// The first `maxBubbles` hints, in the order given, may have bubbles; the
/// one with the fewest spots is placed first (ties in reading order). One
/// with no spot, or past the first `maxBubbles`, goes to the hint list,
/// with a badge on its element.
/// A spot still open is kept when frames change, so bubbles do not jump.
/// The same input always lays out the same way.
public enum UIHintLayout {

    public enum Side: String, Sendable, CaseIterable { case below, right, above, left }

    /// One hint to place.
    public struct Hint: Sendable, Equatable {
        public let id: String
        /// The hinted element, in window points, top-left origin.
        public let target: CGRect
        /// Its bubble's measured size; nil for a ring alone.
        public let bubble: CGSize?
        /// Where its bubble was, relative to its element's origin — kept
        /// there if it still may be, so a scroll moves the two together.
        public let previous: CGRect?

        public init(id: String, target: CGRect, bubble: CGSize?, previous: CGRect? = nil) {
            self.id = id
            self.target = target
            self.bubble = bubble
            self.previous = previous
        }
    }

    public struct Input: Sendable {
        /// The window's visible content.
        public let bounds: CGRect
        public let hints: [Hint]
        /// Other controls on screen: better not covered.
        public let controls: [CGRect]
        /// Images (a FITS or cube canvas): covered last of all.
        public let images: [CGRect]
        public let maxBubbles: Int

        public init(bounds: CGRect, hints: [Hint], controls: [CGRect] = [], images: [CGRect] = [],
                    maxBubbles: Int = UIHintLayout.maxBubbles) {
            self.bounds = bounds
            self.hints = hints
            self.controls = controls
            self.images = images
            self.maxBubbles = maxBubbles
        }
    }

    /// A placed bubble.
    public struct Bubble: Sendable, Equatable {
        public let frame: CGRect
        public let side: Side
        /// Where it touches its element: the tail's tip, or the line's end.
        public let anchor: CGPoint
        /// True when it sits away from its element, joined by a line.
        public let line: Bool
    }

    public struct Placement: Sendable, Equatable {
        public var bubbles: [String: Bubble] = [:]
        /// Hints whose words go in the hint list, in the order given.
        public var listed: [String] = []
        /// Each listed hint's badge, on its element.
        public var badges: [String: CGRect] = [:]
    }

    /// At most this many bubbles show beside their elements.
    public static let maxBubbles = 12
    /// Between bubbles, and from a bubble to what it must not cover.
    public static let gap: CGFloat = 6
    /// From an element to its bubble: room for the tail.
    public static let reach: CGFloat = 8
    static let slideStep: CGFloat = 16
    static let maxSlides = 24
    static let secondRing: CGFloat = 40
    public static let badgeSize = CGSize(width: 18, height: 18)

    // MARK: - Placing

    public static func place(_ input: Input) -> Placement {
        var placement = Placement()
        let hinted = input.hints.map(\.target)
        let wanting = input.hints.enumerated().filter { $0.element.bubble != nil }
        let withBubbles = Array(wanting.prefix(input.maxBubbles))
        placement.listed = wanting.dropFirst(input.maxBubbles).map(\.element.id)

        // Spots that keep rules 2 and 3, before any bubble is placed.
        var open: [Int: [Candidate]] = [:]
        for (index, hint) in withBubbles {
            open[index] = candidates(for: hint, in: input).filter { candidate in
                input.bounds.contains(candidate.frame)
                    && !hinted.contains { $0.intersects(candidate.frame.insetBy(dx: -gap, dy: -gap)) }
            }
        }
        let order = withBubbles.map(\.offset).sorted { a, b in
            let ca = open[a]?.count ?? 0, cb = open[b]?.count ?? 0
            if ca != cb { return ca < cb }
            return readsBefore(input.hints[a].target, input.hints[b].target)
        }

        var placed: [Bubble] = []
        for index in order {
            let hint = input.hints[index]
            let free = (open[index] ?? []).filter { candidate in
                !placed.contains { $0.frame.insetBy(dx: -gap, dy: -gap).intersects(candidate.frame) }
            }
            let kept = hint.previous.flatMap { previous in
                free.first { candidate in
                    let relative = candidate.frame.offsetBy(dx: -hint.target.minX, dy: -hint.target.minY)
                    return abs(relative.minX - previous.minX) < 0.5 && abs(relative.minY - previous.minY) < 0.5
                }
            }
            guard let best = kept ?? free.min(by: { cost($0, input: input, placed: placed) < cost($1, input: input, placed: placed) })
            else {
                placement.listed.append(hint.id)
                continue
            }
            let bubble = Bubble(frame: best.frame, side: best.side, anchor: best.anchor, line: best.line)
            placed.append(bubble)
            placement.bubbles[hint.id] = bubble
        }
        // The list keeps the order the hints were given in.
        let given = Dictionary(uniqueKeysWithValues: input.hints.enumerated().map { ($0.element.id, $0.offset) })
        placement.listed.sort { (given[$0] ?? 0) < (given[$1] ?? 0) }
        placement.badges = badges(for: placement.listed, input: input, bubbles: placed)
        return placement
    }

    /// Where the hint list goes: docked to a side of the window, the side
    /// with the most room first, clear of the hinted elements and the
    /// bubbles. Nil when it fits nowhere — then it shrinks to a pill.
    public static func placeList(size: CGSize, in bounds: CGRect, keepClear: [CGRect]) -> CGRect? {
        let margin: CGFloat = 12
        let inner = bounds.insetBy(dx: margin, dy: margin)
        guard size.width <= inner.width, size.height <= inner.height else { return nil }
        let spots = [
            CGRect(x: inner.maxX - size.width, y: inner.minY, width: size.width, height: size.height),
            CGRect(x: inner.maxX - size.width, y: inner.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: inner.minX, y: inner.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: inner.minX, y: inner.minY, width: size.width, height: size.height),
            CGRect(x: inner.midX - size.width / 2, y: inner.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: inner.midX - size.width / 2, y: inner.minY, width: size.width, height: size.height),
        ]
        return spots.first { spot in !keepClear.contains { $0.insetBy(dx: -gap, dy: -gap).intersects(spot) } }
    }

    // MARK: - Candidates

    private struct Candidate {
        let target: CGRect
        let frame: CGRect
        let side: Side
        let anchor: CGPoint
        let line: Bool
        /// How far it is from the best spot on its side: centred, then start
        /// and end, then each slide, then the second ring.
        let distance: Int
    }

    private static func candidates(for hint: Hint, in input: Input) -> [Candidate] {
        guard let size = hint.bubble else { return [] }
        let t = hint.target
        var all: [Candidate] = []
        for side in Side.allCases {
            for ring in 0..<2 {
                let out = reach + CGFloat(ring) * secondRing
                // Along the side: centred, start, end, then slides both ways.
                var offsets: [(CGFloat, Int)] = []
                switch side {
                case .below, .above:
                    offsets = [(t.midX - size.width / 2, 0), (t.minX, 1), (t.maxX - size.width, 1)]
                    for k in 1...maxSlides {
                        offsets.append((t.midX - size.width / 2 + CGFloat(k) * slideStep, 1 + k))
                        offsets.append((t.midX - size.width / 2 - CGFloat(k) * slideStep, 1 + k))
                    }
                case .left, .right:
                    offsets = [(t.midY - size.height / 2, 0), (t.minY, 1), (t.maxY - size.height, 1)]
                    for k in 1...maxSlides {
                        offsets.append((t.midY - size.height / 2 + CGFloat(k) * slideStep, 1 + k))
                        offsets.append((t.midY - size.height / 2 - CGFloat(k) * slideStep, 1 + k))
                    }
                }
                for (along, distance) in offsets {
                    let frame: CGRect = switch side {
                    case .below: CGRect(x: along, y: t.maxY + out, width: size.width, height: size.height)
                    case .above: CGRect(x: along, y: t.minY - out - size.height, width: size.width, height: size.height)
                    case .right: CGRect(x: t.maxX + out, y: along, width: size.width, height: size.height)
                    case .left: CGRect(x: t.minX - out - size.width, y: along, width: size.width, height: size.height)
                    }
                    let (anchor, touches) = anchorPoint(side: side, target: t, bubble: frame)
                    all.append(Candidate(target: t, frame: frame, side: side, anchor: anchor,
                                         line: ring > 0 || !touches, distance: distance + ring * 100))
                }
            }
        }
        return all
    }

    /// Where a bubble on `side` touches its element, and whether a tail can
    /// reach it straight (the two overlap along that side by 12 pt or more).
    private static func anchorPoint(side: Side, target t: CGRect, bubble b: CGRect) -> (CGPoint, Bool) {
        switch side {
        case .below, .above:
            let lo = max(t.minX, b.minX), hi = min(t.maxX, b.maxX)
            let x = hi - lo >= 12 ? (lo + hi) / 2 : min(max(b.midX, t.minX + 4), t.maxX - 4)
            return (CGPoint(x: x, y: side == .below ? t.maxY : t.minY), hi - lo >= 12)
        case .left, .right:
            let lo = max(t.minY, b.minY), hi = min(t.maxY, b.maxY)
            let y = hi - lo >= 12 ? (lo + hi) / 2 : min(max(b.midY, t.minY + 4), t.maxY - 4)
            return (CGPoint(x: side == .right ? t.maxX : t.minX, y: y), hi - lo >= 12)
        }
    }

    // MARK: - Cost

    private static func cost(_ candidate: Candidate, input: Input, placed: [Bubble]) -> Double {
        let area = Double(candidate.frame.width * candidate.frame.height)
        func covered(_ rects: [CGRect]) -> Double {
            rects.reduce(0) { sum, rect in
                let common = rect.intersection(candidate.frame)
                return common.isNull ? sum : sum + Double(common.width * common.height)
            }
        }
        var total = 100 * covered(input.controls) / area + 400 * covered(input.images) / area
        total += 15 * Double(sideRank(candidate.side, bounds: input.bounds, target: candidate.target))
        total += 3 * Double(candidate.distance)
        if candidate.line {
            total += 10
            let line = (start: edgeMiddle(candidate.frame, facing: candidate.side), end: candidate.anchor)
            for bubble in placed {
                if segment(line.start, line.end, crosses: bubble.frame) { total += 25 }
                if bubble.line, segmentsCross(line.start, line.end,
                                              edgeMiddle(bubble.frame, facing: bubble.side), bubble.anchor) {
                    total += 25
                }
            }
        }
        return total
    }

    /// The side's rank by the room beyond the element: most room first; ties
    /// go below, right, above, left.
    static func sideRank(_ side: Side, bounds b: CGRect, target t: CGRect) -> Int {
        let room: [Side: CGFloat] = [
            .below: b.maxY - t.maxY, .above: t.minY - b.minY, .right: b.maxX - t.maxX, .left: t.minX - b.minX,
        ]
        let ranked = Side.allCases.enumerated().sorted { a, c in
            let ra = (room[a.element] ?? 0).rounded(), rc = (room[c.element] ?? 0).rounded()
            return ra != rc ? ra > rc : a.offset < c.offset
        }
        return ranked.firstIndex { $0.element == side } ?? 0
    }

    /// The middle of the bubble's edge that faces its element.
    private static func edgeMiddle(_ frame: CGRect, facing side: Side) -> CGPoint {
        switch side {
        case .below: CGPoint(x: frame.midX, y: frame.minY)
        case .above: CGPoint(x: frame.midX, y: frame.maxY)
        case .right: CGPoint(x: frame.minX, y: frame.midY)
        case .left: CGPoint(x: frame.maxX, y: frame.midY)
        }
    }

    // MARK: - Badges

    /// A badge on each listed hint's element — at a corner, nudged along the
    /// edge so no two overlap, and none covers another hinted element or a
    /// bubble.
    private static func badges(for ids: [String], input: Input, bubbles: [Bubble]) -> [String: CGRect] {
        let byID = Dictionary(input.hints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [String: CGRect] = [:]
        for id in ids {
            guard let target = byID[id]?.target else { continue }
            let others = input.hints.filter { $0.id != id }.map(\.target)
            let s = badgeSize
            var spots: [CGRect] = []
            for k in 0...8 {
                let step = CGFloat(k) * (s.width + 2)
                spots += [
                    CGRect(x: target.minX - s.width / 2 + step, y: target.minY - s.height / 2, width: s.width, height: s.height),
                    CGRect(x: target.maxX - s.width / 2 - step, y: target.minY - s.height / 2, width: s.width, height: s.height),
                    CGRect(x: target.minX - s.width / 2 + step, y: target.maxY - s.height / 2, width: s.width, height: s.height),
                ]
            }
            let fits = spots.first { spot in
                input.bounds.contains(spot)
                    && !placed.values.contains { $0.insetBy(dx: -2, dy: -2).intersects(spot) }
                    && !others.contains { $0.intersects(spot) }
                    && !bubbles.contains { $0.frame.intersects(spot) }
            }
            placed[id] = fits ?? spots[0]
        }
        return placed
    }

    // MARK: - Geometry

    /// Top to bottom, then left to right; a row is anything within 6 pt.
    static func readsBefore(_ a: CGRect, _ b: CGRect) -> Bool {
        let rowA = (a.minY / 6).rounded(.down), rowB = (b.minY / 6).rounded(.down)
        return rowA != rowB ? rowA < rowB : a.minX < b.minX
    }

    static func segment(_ p: CGPoint, _ q: CGPoint, crosses rect: CGRect) -> Bool {
        if rect.contains(p) || rect.contains(q) { return true }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        return (0..<4).contains { segmentsCross(p, q, corners[$0], corners[($0 + 1) % 4]) }
    }

    static func segmentsCross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func turn(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let d1 = turn(c, d, a), d2 = turn(c, d, b), d3 = turn(a, b, c), d4 = turn(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
