// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// The geometry every viewer's marks share: where a mark is drawn, where
/// its grips and words are, what is under the pointer, and what a drag
/// asks for. The overlay draws from these answers and the gestures test
/// against them, so what you see and what you can grab are the same shapes.
/// Free of any drawing API; all lengths are screen points.
enum MarkGeometry {

    /// The smallest half-size a mark is drawn or dragged to. In screen
    /// points, never the anchor's units: half a unit is half a pixel on an
    /// image and half a *degree* on the sky (Windows drew a box 19 000 px
    /// wide that way). A mark zoomed far out stays visible and grabbable.
    static let minimumHalf: Double = 4
    /// A new shape's half-size before the drag that sizes it, so a click
    /// makes a mark you can see.
    static let initialHalf: Double = 12
    static let handleRadius: Double = 4
    /// A grip is a little easier to hit than it looks.
    static let handleReach: Double = handleRadius + 4
    /// The middle of a selected mark always moves it, even when its four
    /// grips cover a small shape.
    static let coreHalf: Double = 4
    /// How far the pointer may travel and still be a click.
    static let clickSlop: Double = 3
    /// A hairline shape a few points across is hit by a near miss.
    static let hitMinimum: Double = 6
    /// Gap between a shape or leader and its words.
    static let labelGap: Double = 4

    // MARK: - Where a mark is

    /// A mark's centre, drawn half-size (floored) and turn on screen.
    struct Frame: Equatable {
        let centre: CGPoint
        /// Zero for a mark without a size (a text or a bare callout).
        let half: CGSize
        let rotation: Double

        /// `point` in the shape's own axes, centre at the origin.
        func local(_ point: CGPoint) -> CGPoint {
            let dx = point.x - centre.x, dy = point.y - centre.y
            let c = cos(-rotation), s = sin(-rotation)
            return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
        }

        /// A point in the shape's own axes, back on screen.
        func screen(_ local: CGPoint) -> CGPoint {
            let c = cos(rotation), s = sin(rotation)
            return CGPoint(x: centre.x + local.x * c - local.y * s, y: centre.y + local.x * s + local.y * c)
        }
    }

    /// Nil when the mark has no place on this view.
    static func frame(of mark: Mark, in projection: MarkProjection) -> Frame? {
        guard let centre = projection.point(mark.anchor), centre.x.isFinite, centre.y.isFinite else { return nil }
        guard let extent = mark.extent else { return Frame(centre: centre, half: .zero, rotation: projection.rotation) }
        guard let half = projection.halfSize(extent, mark.anchor), half.width.isFinite, half.height.isFinite else { return nil }
        return Frame(centre: centre,
                     half: CGSize(width: max(half.width, minimumHalf), height: max(half.height, minimumHalf)),
                     rotation: projection.rotation)
    }

    /// The four resize grips, on the shape's corners; none without a size.
    static func handles(of mark: Mark, frame: Frame) -> [CGPoint] {
        guard mark.extent != nil else { return [] }
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map {
            frame.screen(CGPoint(x: $0.0 * frame.half.width, y: $0.1 * frame.half.height))
        }
    }

    // MARK: - Words

    /// Where a mark's words go.
    struct Label: Equatable {
        /// A callout's leader, from the shape's edge to the words.
        let leader: (from: CGPoint, to: CGPoint)?
        /// The point the words are placed at…
        let at: CGPoint
        /// …and which point of them sits there (0…1 across, 0…1 down).
        let alignment: CGPoint
        /// Where the words are, estimated — the drawn words and the part
        /// that can be clicked must agree.
        let box: CGRect

        static func == (a: Label, b: Label) -> Bool {
            a.at == b.at && a.alignment == b.alignment && a.box == b.box
                && a.leader?.from == b.leader?.from && a.leader?.to == b.leader?.to
        }
    }

    /// Nil for a mark with no words, unless `always` (the naming field
    /// needs a place before there are any).
    static func label(of mark: Mark, frame: Frame, always: Bool = false) -> Label? {
        let text = mark.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard always || !text.isEmpty else { return nil }
        let style = mark.effectiveStyle
        let size = CGSize(width: textWidth(text, style: style), height: style.fontSize * 1.25)

        let leader: (from: CGPoint, to: CGPoint)?
        let at: CGPoint
        let alignment: CGPoint
        switch mark.kind {
        case .callout:
            let offset = CGPoint(x: mark.labelOffsetX ?? Mark.defaultLabelOffset.x,
                                 y: mark.labelOffsetY ?? Mark.defaultLabelOffset.y)
            let end = CGPoint(x: frame.centre.x + offset.x, y: frame.centre.y + offset.y)
            leader = (edge(of: mark, frame: frame, towards: end), end)
            let rightwards = offset.x >= 0
            at = CGPoint(x: end.x + (rightwards ? labelGap : -labelGap), y: end.y)
            alignment = CGPoint(x: rightwards ? 0 : 1, y: 0.5)
        case .text:
            leader = nil
            at = frame.centre
            alignment = CGPoint(x: 0.5, y: 0.5)
        case .circle, .rect:
            leader = nil
            at = CGPoint(x: frame.centre.x + frame.half.width + labelGap, y: frame.centre.y - frame.half.height)
            alignment = CGPoint(x: 0, y: 1)
        }
        let box = CGRect(x: at.x - alignment.x * size.width, y: at.y - alignment.y * size.height,
                         width: size.width, height: size.height)
        return Label(leader: leader, at: at, alignment: alignment, box: box)
    }

    /// A width for words without laying them out — a little generous, so
    /// the clickable box covers the drawn words.
    static func textWidth(_ text: String, style: Mark.Style) -> Double {
        Double(max(text.count, 1)) * style.fontSize * (style.bold ? 0.62 : 0.56)
    }

    /// Where a leader leaves the shape: on its outline, along the line to
    /// `end` — not its corner (outside a circle) nor its centre (a line
    /// through the subject).
    static func edge(of mark: Mark, frame: Frame, towards end: CGPoint) -> CGPoint {
        let d = frame.local(end)
        let hw = frame.half.width, hh = frame.half.height
        guard hw > 0, hh > 0, d.x != 0 || d.y != 0 else { return frame.centre }
        let t: Double
        if mark.kind == .rect {
            t = min(d.x == 0 ? .infinity : hw / abs(d.x), d.y == 0 ? .infinity : hh / abs(d.y))
        } else {
            t = 1 / ((d.x / hw) * (d.x / hw) + (d.y / hh) * (d.y / hh)).squareRoot()
        }
        return frame.screen(CGPoint(x: d.x * min(t, 1), y: d.y * min(t, 1)))
    }

    // MARK: - What is under the pointer

    /// Whether `point` is on the mark's shape (a near miss counts) or its words.
    static func contains(_ point: CGPoint, mark: Mark, frame: Frame) -> Bool {
        let p = frame.local(point)
        if abs(p.x) <= max(frame.half.width, hitMinimum), abs(p.y) <= max(frame.half.height, hitMinimum) { return true }
        return label(of: mark, frame: frame)?.box.insetBy(dx: -2, dy: -2).contains(point) ?? false
    }

    /// The topmost mark at `point`. A mark with no place here is skipped,
    /// not the end of the search.
    static func mark(at point: CGPoint, in marks: [Mark], projection: MarkProjection) -> Mark? {
        marks.reversed().first { mark in
            frame(of: mark, in: projection).map { contains(point, mark: mark, frame: $0) } ?? false
        }
    }

    /// What a press asks for.
    enum Grab: Equatable {
        /// Nothing of the marks': the view pans or places its crosshair.
        case none
        /// Draw a new mark here.
        case place
        /// Move this mark, held `offset` from its centre (so it does not
        /// jump to centre itself under the pointer).
        case move(id: String, offset: CGSize)
        /// Resize this mark by a grip.
        case resize(id: String)
    }

    /// The order decides it: a grip of the selected mark (grips sit on
    /// the outline, so the shape would win otherwise) unless the press is
    /// on its core; then any mark; then empty space — which draws only when
    /// drawing is armed, so marks can still be moved with the pencil up.
    static func grab(at point: CGPoint, in marks: [Mark], projection: MarkProjection,
                     selectedID: String?, drawing: Bool) -> Grab {
        if let selected = marks.first(where: { $0.id == selectedID }),
           let f = frame(of: selected, in: projection) {
            let core = f.local(point)
            let onCore = abs(core.x) <= coreHalf && abs(core.y) <= coreHalf
            let onGrip = handles(of: selected, frame: f).contains {
                abs($0.x - point.x) <= handleReach && abs($0.y - point.y) <= handleReach
            }
            if onGrip && !onCore { return .resize(id: selected.id) }
        }
        if let hit = mark(at: point, in: marks, projection: projection) {
            let centre = projection.point(hit.anchor) ?? point
            return .move(id: hit.id, offset: CGSize(width: point.x - centre.x, height: point.y - centre.y))
        }
        return drawing ? .place : .none
    }

    // MARK: - What a drag asks for

    /// `points` on screen in the anchor's own units.
    static func units(_ points: Double, at anchor: Mark.Anchor, projection: MarkProjection) -> Double? {
        projection.scale(at: anchor).map { points / $0 }
    }

    /// The size a grip dragged to `point` asks for, in the anchor's units.
    /// Measured and floored on screen, converted once. A box takes each
    /// side from the drag; a circle or callout keeps its proportions.
    static func resized(_ mark: Mark, to point: CGPoint, projection: MarkProjection) -> Mark.Extent? {
        guard let centre = projection.point(mark.anchor), let scale = projection.scale(at: mark.anchor) else { return nil }
        let f = Frame(centre: centre, half: .zero, rotation: projection.rotation)
        let p = f.local(point)
        let dx = max(abs(p.x), minimumHalf), dy = max(abs(p.y), minimumHalf)
        guard dx.isFinite, dy.isFinite else { return nil }
        if mark.kind == .rect { return Mark.Extent(halfWidth: dx / scale, halfHeight: dy / scale) }
        let current = mark.extent ?? .square(1)
        let ratio = current.halfHeight / current.halfWidth
        let halfWidth = max(dx, dy / ratio) / scale
        return Mark.Extent(halfWidth: halfWidth, halfHeight: halfWidth * ratio)
    }
}
