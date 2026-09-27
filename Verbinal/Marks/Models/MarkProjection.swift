// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics

/// What a viewer answers for its marks: where an anchor is on its screen,
/// how big a unit of it is there, and which anchor a point on its screen
/// means. This is all the FITS canvas and the cube differ by — drawing,
/// hit-testing and gestures (`MarkGeometry`, `MarkEditor`) are shared.
struct MarkProjection {
    /// The anchor on screen, or nil when it has no place here.
    let point: (Mark.Anchor) -> CGPoint?
    /// Screen half-size of an extent at an anchor.
    let halfSize: (Mark.Extent, Mark.Anchor) -> CGSize?
    /// The anchor a screen point means. For a new mark (`moving` nil) the
    /// viewer picks the space — the sky when it has a WCS — and a point off
    /// the image is a miss. A moved mark keeps its space (and a cube mark
    /// its channel), and slides along the edge rather than off it.
    var anchor: (_ at: CGPoint, _ moving: Mark.Anchor?) -> Mark.Anchor? = { _, _ in nil }
    /// The view's rotation, so a box turns with the image.
    var rotation: Double = 0

    /// Screen points per unit of the anchor's space; nil where it has none.
    func scale(at anchor: Mark.Anchor) -> Double? {
        guard let points = halfSize(.square(1), anchor)?.width, points.isFinite, points > 0 else { return nil }
        return points
    }
}
