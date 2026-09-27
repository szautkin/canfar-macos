// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics

/// Where the cube's slice is on screen: fitted to the canvas, then zoomed
/// about the canvas centre and panned. The one map between the screen and
/// the cube's 0-based voxels — the spectrum probe, the cursor read-out and
/// marks all go through it.
struct CubeSliceFrame: Equatable {
    let grid: FITSDisplayGrid
    let canvas: CGSize
    let zoom: CGFloat
    let pan: CGSize

    init?(nx: Int, ny: Int, canvas: CGSize, zoom: CGFloat, pan: CGSize) {
        guard nx > 0, ny > 0, canvas.width > 0, canvas.height > 0, zoom > 0 else { return nil }
        grid = FITSDisplayGrid(width: nx, height: ny)
        self.canvas = canvas
        self.zoom = zoom
        self.pan = pan
    }

    /// Screen points per voxel.
    var scale: CGFloat {
        min(canvas.width / CGFloat(grid.width), canvas.height / CGFloat(grid.height)) * zoom
    }

    func screen(ofDisplay point: CGPoint) -> CGPoint {
        CGPoint(x: canvas.width / 2 + (point.x - CGFloat(grid.width) / 2) * scale + pan.width,
                y: canvas.height / 2 + (point.y - CGFloat(grid.height) / 2) * scale + pan.height)
    }

    func display(ofScreen point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - canvas.width / 2 - pan.width) / scale + CGFloat(grid.width) / 2,
                y: (point.y - canvas.height / 2 - pan.height) / scale + CGFloat(grid.height) / 2)
    }

    /// Where voxel centre (x, y) is on screen.
    func screen(ofVoxel x: Double, _ y: Double) -> CGPoint {
        screen(ofDisplay: grid.display(ofPixel: x, y))
    }

    /// Continuous voxel coordinates under a screen point; nil off the slice.
    func voxel(atScreen point: CGPoint) -> (x: Double, y: Double)? {
        let display = display(ofScreen: point)
        return grid.contains(display: display) ? grid.pixel(ofDisplay: display) : nil
    }

    /// The voxel whose square is under a screen point; nil off the slice.
    func voxelIndex(atScreen point: CGPoint) -> (x: Int, y: Int)? {
        let display = display(ofScreen: point)
        return grid.contains(display: display) ? grid.index(ofDisplay: display) : nil
    }

    /// The pan that puts voxel (x, y) at the canvas centre.
    func panCentring(voxel x: Double, _ y: Double) -> CGSize {
        let d = grid.display(ofPixel: x, y)
        return CGSize(width: -(d.x - CGFloat(grid.width) / 2) * scale, height: -(d.y - CGFloat(grid.height) / 2) * scale)
    }

    /// The pan that keeps the point under `anchor` still while zooming to `newZoom`.
    func panKeeping(_ anchor: CGPoint, atZoom newZoom: CGFloat) -> CGSize {
        let d = display(ofScreen: anchor)
        let s = scale / zoom * newZoom
        return CGSize(width: anchor.x - canvas.width / 2 - (d.x - CGFloat(grid.width) / 2) * s,
                      height: anchor.y - canvas.height / 2 - (d.y - CGFloat(grid.height) / 2) * s)
    }
}
