// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics

/// A displayed image's grid — row 0 on top, points in pixels from its
/// top-left corner — against 0-based FITS pixel centres (row 0 at the
/// bottom). The one place for the half pixel and the row flip, which the
/// FITS viewer and the cube slice both need: a pixel's centre is half a
/// pixel in from its corner, and a map that forgets it lands a click on
/// the neighbouring pixel half the time.
struct FITSDisplayGrid: Equatable {
    let width: Int
    let height: Int

    /// Where FITS pixel centre (x, y) is drawn.
    func display(ofPixel x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x + 0.5, y: Double(height) - y - 0.5)
    }

    /// The FITS pixel coordinates (continuous) drawn at a display point.
    func pixel(ofDisplay point: CGPoint) -> (x: Double, y: Double) {
        (point.x - 0.5, Double(height) - point.y - 0.5)
    }

    /// The FITS pixel whose square a display point is in.
    func index(ofDisplay point: CGPoint) -> (x: Int, y: Int) {
        (Int(point.x.rounded(.down)), height - 1 - Int(point.y.rounded(.down)))
    }

    func contains(display point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < Double(width) && point.y < Double(height)
    }

    /// The nearest point on the image — a drag carried past the edge
    /// slides along it.
    func clamped(display point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), Double(width)), y: min(max(point.y, 0), Double(height)))
    }
}
