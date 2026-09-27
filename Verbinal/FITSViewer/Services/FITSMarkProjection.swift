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

    /// Marks on this canvas: the display image → the screen.
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
            rotation: viewport.rotation)
    }
}
