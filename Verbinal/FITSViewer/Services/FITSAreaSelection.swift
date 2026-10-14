// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// Select Area (Windows parity): a box dragged on the image — armed from
/// the toolbar, or with ⌘ held — becomes the region of a figure, and
/// Export Figure opens on it. The gesture and the figure are one action.
extension FITSViewerModel {

    /// The figure region a box dragged from `start` to `end` on the canvas
    /// covers: the image pixels under it, whole, as a FITS pixel box
    /// (`FITSFigureRegion.box`). Nil when it covers no pixel of the image.
    func areaRegion(from start: CGPoint, to end: CGPoint, canvasSize: CGSize) -> FITSFigureRegion? {
        guard let grid = displayGrid, let transform = displayTransform(canvasSize: canvasSize) else { return nil }
        // Each corner, as the view may be turned or flipped.
        let corners = [start, CGPoint(x: end.x, y: start.y), CGPoint(x: start.x, y: end.y), end].map(transform.screenToImage)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(CGRect(x: 0, y: 0, width: grid.width, height: grid.height))
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let left = box.minX.rounded(.down), right = box.maxX.rounded(.up)
        let top = box.minY.rounded(.down), bottom = box.maxY.rounded(.up)
        // The display grid's rows go down; FITS rows go up.
        return .box(x: left, y: Double(grid.height) - bottom, width: right - left, height: bottom - top)
    }

    /// Select Area turned on or off — by its button's twin for an
    /// assistant (`set_fits_view` `selectArea`). Answers why not when there
    /// is no image to select from.
    func setSelectingArea(_ on: Bool) -> String? {
        guard !on || renderedImage != nil else { return "The active tab shows no image to select an area of" }
        selectingArea = on
        if !on { areaBand = nil }
        return nil
    }

    /// A box dragged out and let go: Export Figure opens on what it covers,
    /// and Select Area puts itself down. Answers why not when it covers
    /// nothing of the image.
    func finishArea(from start: CGPoint, to end: CGPoint, canvasSize: CGSize) -> String? {
        areaBand = nil
        guard let region = areaRegion(from: start, to: end, canvasSize: canvasSize) else {
            return String(localized: "That area is off the image")
        }
        selectingArea = false
        figureRegion = region
        return nil
    }
}

extension FITSFigureRegion {
    /// A box's size in pixels, as the Export Figure sheet names it.
    var boxSize: (width: Int, height: Int)? {
        guard case .box(_, _, let width, let height) = self else { return nil }
        return (Int(width), Int(height))
    }
}
