// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

extension FITSViewerModel {
    /// Where the marks kept with this tab's file and extension live.
    var markTarget: MarkStore.Target? {
        fileURL.map { MarkStore.Target(file: $0, hdu: selectedHDUIndex) }
    }

    /// Where a mark's anchor falls on the display image (row 0 on top):
    /// 0-based FITS array pixels, or the sky through the WCS.
    func displayPoint(_ anchor: Mark.Anchor) -> CGPoint? {
        guard let hdu = selectedHDU else { return nil }
        let pixel: (x: Double, y: Double)
        switch anchor.space {
        case .imagePixel, .data:
            pixel = (anchor.x, anchor.y)
        case .sky:
            guard let wcs, let p = wcs.worldToPixel(ra: anchor.x, dec: anchor.y) else { return nil }
            pixel = (p.x, p.y)
        }
        return CGPoint(x: pixel.x + 0.5, y: Double(hdu.header.naxis2) - pixel.y - 0.5)
    }

    /// The anchor a display-image point means: on the sky when the image
    /// has a WCS (so the mark finds the same place in another image of the
    /// field), else on its pixels. A new mark off the image is a miss; a
    /// moved one keeps its space and slides along the edge.
    func anchor(atDisplay point: CGPoint, moving: Mark.Anchor?) -> Mark.Anchor? {
        guard let hdu = selectedHDU else { return nil }
        let width = Double(hdu.header.naxis1), height = Double(hdu.header.naxis2)
        let inside = point.x >= 0 && point.y >= 0 && point.x < width && point.y < height
        guard moving != nil || inside else { return nil }
        let x = min(max(point.x, 0), width) - 0.5
        let y = height - min(max(point.y, 0), height) - 0.5
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

    /// Marks on this canvas: the display image ↔ the screen.
    func markProjection(canvasSize: CGSize) -> MarkProjection? {
        guard let transform = displayTransform(canvasSize: canvasSize) else { return nil }
        let wcs = self.wcs
        let zoom = viewport.zoom
        return MarkProjection(
            point: { [weak self] anchor in self?.displayPoint(anchor).map(transform.imageToScreen) },
            halfSize: { extent, anchor in
                let perUnit: Double
                switch anchor.space {
                case .imagePixel, .data:
                    perUnit = zoom
                case .sky:
                    guard let wcs, wcs.pixelScaleArcsec > 0 else { return nil }
                    perUnit = zoom * 3600 / wcs.pixelScaleArcsec
                }
                return CGSize(width: extent.halfWidth * perUnit, height: extent.halfHeight * perUnit)
            },
            anchor: { [weak self] screen, moving in
                self?.anchor(atDisplay: transform.screenToImage(screen), moving: moving)
            },
            rotation: viewport.rotation)
    }
}
