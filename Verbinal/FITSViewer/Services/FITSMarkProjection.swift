// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation
import VerbinalKit

/// Marks through a FITS image's grid and WCS: where an anchor is on the
/// displayed image, which anchor a point of it means, and how big a mark
/// is in its pixels. The viewer's canvas and the exported figure put these
/// on their own surface (`projection`), so a mark lands on the same pixel
/// in both.
struct FITSMarkPlacement {
    let grid: FITSDisplayGrid
    let wcs: FITSWCSTransform?

    /// Where a mark's anchor falls on the display image (row 0 on top):
    /// 0-based FITS array pixels, or the sky through the WCS.
    func displayPoint(_ anchor: Mark.Anchor) -> CGPoint? {
        switch anchor.space {
        case .imagePixel, .data:
            return grid.display(ofPixel: anchor.x, anchor.y)
        case .sky:
            guard let wcs, let p = wcs.worldToPixel(ra: anchor.x, dec: anchor.y) else { return nil }
            return grid.display(ofPixel: p.x, p.y)
        }
    }

    /// The anchor a display-image point means: on the sky when the image
    /// has a WCS (so the mark finds the same place in another image of the
    /// field), else on its pixels. A new mark off the image is a miss; a
    /// moved one keeps its space and slides along the edge.
    func anchor(atDisplay point: CGPoint, moving: Mark.Anchor?) -> Mark.Anchor? {
        guard moving != nil || grid.contains(display: point) else { return nil }
        let (x, y) = grid.pixel(ofDisplay: grid.clamped(display: point))
        switch moving?.space ?? (wcs != nil ? .sky : .imagePixel) {
        case .sky:
            guard let wcs else { return nil }
            let world = wcs.pixelToWorld(x: x, y: y)
            let ra = world.ra.truncatingRemainder(dividingBy: 360)
            let anchor = Mark.Anchor(space: .sky, x: ra < 0 ? ra + 360 : ra, y: world.dec)
            return anchor.isValid ? anchor : nil
        case .imagePixel, .data:
            return Mark.Anchor(space: .imagePixel, x: x, y: y)
        }
    }

    /// An extent in image pixels; nil for a sky extent without a WCS scale.
    func pixels(_ extent: Mark.Extent, at anchor: Mark.Anchor) -> CGSize? {
        let perUnit: Double
        switch anchor.space {
        case .imagePixel, .data:
            perUnit = 1
        case .sky:
            guard let wcs, wcs.pixelScaleArcsec > 0 else { return nil }
            perUnit = 3600 / wcs.pixelScaleArcsec
        }
        return CGSize(width: extent.halfWidth * perUnit, height: extent.halfHeight * perUnit)
    }

    /// Marks on a surface that shows the display image through
    /// `toSurface` at `pointsPerPixel`; `fromSurface` lets marks be placed
    /// there (nil: drawn only).
    func projection(pointsPerPixel: Double, rotation: Double, toSurface: @escaping (CGPoint) -> CGPoint,
                    fromSurface: ((CGPoint) -> CGPoint)? = nil) -> MarkProjection {
        MarkProjection(
            point: { anchor in displayPoint(anchor).map(toSurface) },
            halfSize: { extent, anchor in
                pixels(extent, at: anchor).map { CGSize(width: $0.width * pointsPerPixel, height: $0.height * pointsPerPixel) }
            },
            anchor: { point, moving in
                fromSurface.flatMap { anchor(atDisplay: $0(point), moving: moving) }
            },
            rotation: rotation)
    }
}

extension FITSViewerModel {
    /// Where the marks kept with this tab's file and extension live.
    var markTarget: MarkStore.Target? {
        fileURL.map { MarkStore.Target(file: $0, hdu: selectedHDUIndex) }
    }

    /// The displayed image's grid, once an HDU is chosen.
    var displayGrid: FITSDisplayGrid? {
        selectedHDU.map { FITSDisplayGrid(width: $0.header.naxis1, height: $0.header.naxis2) }
    }

    var markPlacement: FITSMarkPlacement? {
        displayGrid.map { FITSMarkPlacement(grid: $0, wcs: wcs) }
    }

    func displayPoint(_ anchor: Mark.Anchor) -> CGPoint? {
        markPlacement?.displayPoint(anchor)
    }

    /// Marks on this canvas: the display image ↔ the screen.
    func markProjection(canvasSize: CGSize) -> MarkProjection? {
        guard let placement = markPlacement, let transform = displayTransform(canvasSize: canvasSize) else { return nil }
        return placement.projection(pointsPerPixel: viewport.zoom, rotation: viewport.rotation,
                                    toSurface: transform.imageToScreen, fromSurface: transform.screenToImage)
    }
}
