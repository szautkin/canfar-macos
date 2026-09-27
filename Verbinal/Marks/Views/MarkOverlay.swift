// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Draws marks — one renderer, so a mark looks the same wherever it is.
/// Positions come from `MarkGeometry`, which the gestures hit-test against.
struct MarkOverlay: View {
    let marks: [Mark]
    let selectedID: String?
    /// The mark whose words are being typed: its field shows them instead.
    var namingID: String?
    let projection: MarkProjection
    /// Off where marks cannot be resized (the cube's volume).
    var showsGrips = true

    var body: some View {
        Canvas { context, _ in
            for mark in marks {
                guard let frame = MarkGeometry.frame(of: mark, in: projection) else { continue }
                draw(mark, frame: frame, selected: mark.id == selectedID, in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ mark: Mark, frame: MarkGeometry.Frame, selected: Bool, in context: inout GraphicsContext) {
        let style = mark.effectiveStyle
        let ink = Color(hex: style.colour)

        if mark.extent != nil {
            let box = CGRect(x: -frame.half.width, y: -frame.half.height,
                             width: frame.half.width * 2, height: frame.half.height * 2)
            let outline: Path = mark.kind == .rect ? Path(box) : Path(ellipseIn: box)
            var shaped = context
            shaped.translateBy(x: frame.centre.x, y: frame.centre.y)
            shaped.rotate(by: .radians(frame.rotation))
            if selected {
                shaped.stroke(outline, with: .color(.white.opacity(0.8)),
                              style: StrokeStyle(lineWidth: style.stroke + 3, dash: [4, 3]))
            }
            shaped.stroke(outline, with: .color(ink), lineWidth: style.stroke)
        } else if selected {
            let dot = CGRect(x: frame.centre.x - 3, y: frame.centre.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(ink))
        }

        if let label = MarkGeometry.label(of: mark, frame: frame) {
            if let leader = label.leader {
                var line = Path()
                line.move(to: leader.from)
                line.addLine(to: leader.to)
                context.stroke(line, with: .color(ink), lineWidth: max(1, style.stroke))
            }
            if mark.id != namingID {
                let text = Text(mark.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: style.fontSize, weight: style.bold ? .semibold : .regular))
                    .foregroundStyle(ink)
                context.draw(text, at: label.at, anchor: UnitPoint(x: label.alignment.x, y: label.alignment.y))
            }
        }

        if selected && showsGrips {
            for grip in MarkGeometry.handles(of: mark, frame: frame) {
                let r = MarkGeometry.handleRadius
                let dot = Path(ellipseIn: CGRect(x: grip.x - r, y: grip.y - r, width: 2 * r, height: 2 * r))
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(ink), lineWidth: 1.5)
            }
        }
    }
}

extension Color {
    /// `#rrggbb` in sRGB, for storage and MCP.
    var hexString: String? {
        #if os(macOS)
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #endif
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// `#rrggbb`; anything else is the user ink.
    init(hex: String) {
        let digits = Mark.Style.normalisedColour(hex) ?? Mark.Style.userDefault.colour
        let value = UInt32(digits.dropFirst(), radix: 16) ?? 0x9ed9ff
        self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255, opacity: 1)
    }
}
