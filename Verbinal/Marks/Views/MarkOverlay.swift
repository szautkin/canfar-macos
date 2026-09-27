// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// How a viewer turns a mark into points on its screen. The FITS canvas and
/// the cube supply their own; everything drawn from it is shared.
struct MarkProjection {
    /// The anchor on screen, or nil when it has no place here.
    let point: (Mark.Anchor) -> CGPoint?
    /// Screen half-size of an extent at an anchor.
    let halfSize: (Mark.Extent, Mark.Anchor) -> CGSize?
    /// The view's rotation, so a box turns with the image.
    var rotation: Double = 0
}

/// Draws marks — one renderer, so a mark looks the same wherever it is.
struct MarkOverlay: View {
    let marks: [Mark]
    let selectedID: String?
    let projection: MarkProjection

    var body: some View {
        Canvas { context, _ in
            for mark in marks {
                draw(mark, selected: mark.id == selectedID, in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ mark: Mark, selected: Bool, in context: inout GraphicsContext) {
        guard let centre = projection.point(mark.anchor) else { return }
        let style = mark.effectiveStyle
        let ink = Color(hex: style.colour)
        var shapeFrame = CGRect(origin: centre, size: .zero)

        if let extent = mark.extent, let half = projection.halfSize(extent, mark.anchor) {
            shapeFrame = CGRect(x: -half.width, y: -half.height, width: half.width * 2, height: half.height * 2)
            let outline: Path = mark.kind == .rect ? Path(shapeFrame) : Path(ellipseIn: shapeFrame)
            var shaped = context
            shaped.translateBy(x: centre.x, y: centre.y)
            shaped.rotate(by: .radians(projection.rotation))
            if selected {
                shaped.stroke(outline, with: .color(.white.opacity(0.8)),
                              style: StrokeStyle(lineWidth: style.stroke + 3, dash: [4, 3]))
            }
            shaped.stroke(outline, with: .color(ink), lineWidth: style.stroke)
            shapeFrame = shapeFrame.offsetBy(dx: centre.x, dy: centre.y)
        }

        let text = mark.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let label = Text(text)
            .font(.system(size: style.fontSize, weight: style.bold ? .semibold : .regular))
            .foregroundStyle(ink)
        switch mark.kind {
        case .callout:
            let offset = CGPoint(x: mark.labelOffsetX ?? Mark.defaultLabelOffset.x,
                                 y: mark.labelOffsetY ?? Mark.defaultLabelOffset.y)
            let end = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
            var leader = Path()
            leader.move(to: edgePoint(of: shapeFrame, towards: end, centre: centre))
            leader.addLine(to: end)
            context.stroke(leader, with: .color(ink), lineWidth: max(1, style.stroke))
            context.draw(label, at: CGPoint(x: end.x + (offset.x >= 0 ? 4 : -4), y: end.y),
                         anchor: offset.x >= 0 ? .leading : .trailing)
        case .text:
            context.draw(label, at: centre, anchor: .center)
        case .circle, .rect:
            context.draw(label, at: CGPoint(x: shapeFrame.maxX + 4, y: shapeFrame.minY), anchor: .bottomLeading)
        }
    }

    /// Where a leader leaves the shape — its edge towards the label, or the
    /// anchor itself for a callout without one.
    private func edgePoint(of frame: CGRect, towards end: CGPoint, centre: CGPoint) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return centre }
        let dx = end.x - centre.x, dy = end.y - centre.y
        let length = max(hypot(dx, dy), 1)
        return CGPoint(x: centre.x + dx / length * frame.width / 2, y: centre.y + dy / length * frame.height / 2)
    }
}

extension Color {
    /// `#rrggbb`; anything else is the user ink.
    init(hex: String) {
        let digits = Mark.Style.normalisedColour(hex) ?? Mark.Style.userDefault.colour
        let value = UInt32(digits.dropFirst(), radix: 16) ?? 0x9ed9ff
        self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255, opacity: 1)
    }
}
