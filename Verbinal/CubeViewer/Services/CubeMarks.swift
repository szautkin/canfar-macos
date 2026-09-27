// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// Marks on a cube live on a channel: pinned to a voxel (x, y, channel)
/// and drawn on the slice showing that channel, not on every slice.
extension CubeViewerModel {

    /// Where this cube's marks are kept (a cube has one data unit here).
    var markTarget: MarkStore.Target? {
        fileURL.map { MarkStore.Target(file: $0, hdu: nil) }
    }

    /// Marks on the slice: voxels of the channel on screen ↔ the screen. A
    /// new mark lands on the channel shown; a moved one keeps its own.
    func sliceMarkProjection(canvasSize: CGSize) -> MarkProjection? {
        guard let frame = sliceFrame(canvasSize: canvasSize) else { return nil }
        let channel = channel
        return MarkProjection(
            point: { anchor in
                guard anchor.space == .data, Int(anchor.z.rounded()) == channel else { return nil }
                return frame.screen(ofVoxel: anchor.x, anchor.y)
            },
            halfSize: { extent, anchor in
                anchor.space == .data
                    ? CGSize(width: extent.halfWidth * frame.scale, height: extent.halfHeight * frame.scale) : nil
            },
            anchor: { point, moving in
                let display = frame.display(ofScreen: point)
                guard moving != nil || frame.grid.contains(display: display) else { return nil }
                let voxel = frame.grid.pixel(ofDisplay: frame.grid.clamped(display: display))
                return Mark.Anchor(space: .data, x: voxel.x, y: voxel.y, z: moving?.z ?? Double(channel))
            })
    }

    /// Marks in the volume: every channel's, where the camera sees them.
    /// Drawn only — marks are placed and moved on the slice.
    func volumeMarkProjection(canvasSize: CGSize) -> MarkProjection? {
        guard nz > 0, let camera = camera(for: canvasSize) else { return nil }
        let (nx, ny, nz) = (self.nx, self.ny, self.nz)
        func screen(_ x: Double, _ y: Double, _ z: Double) -> CGPoint? {
            camera.screen(ofBoxPoint: CubeCamera.boxPoint(voxelX: x, y, z, nx: nx, ny: ny, nz: nz), in: canvasSize)
        }
        // How the cube's x axis runs on screen, at its centre.
        let middle = (x: Double(nx) / 2, y: Double(ny) / 2, z: Double(nz) / 2)
        var rotation = 0.0
        if let a = screen(middle.x, middle.y, middle.z), let b = screen(middle.x + 1, middle.y, middle.z) {
            rotation = atan2(b.y - a.y, b.x - a.x)
        }
        return MarkProjection(
            point: { anchor in anchor.space == .data ? screen(anchor.x, anchor.y, anchor.z) : nil },
            halfSize: { extent, anchor in
                guard anchor.space == .data, let centre = screen(anchor.x, anchor.y, anchor.z),
                      let across = screen(anchor.x + extent.halfWidth, anchor.y, anchor.z),
                      let up = screen(anchor.x, anchor.y + extent.halfHeight, anchor.z) else { return nil }
                return CGSize(width: hypot(across.x - centre.x, across.y - centre.y),
                              height: hypot(up.x - centre.x, up.y - centre.y))
            },
            rotation: rotation)
    }

    /// The orbit camera on a view of `size`; `distanceScale` pulls it back
    /// (figure export).
    func camera(for size: CGSize, distanceScale: Float = 1) -> CubeCamera? {
        guard nx > 0, ny > 0, size.width > 1, size.height > 1 else { return nil }
        return CubeCamera(azimuth: cameraAzimuth, elevation: cameraElevation, distance: cameraDistance * distanceScale,
                          boxScale: CubeCamera.boxScale(nx: nx, ny: ny, spectralScale: spectralScale),
                          aspect: Float(size.width / size.height))
    }

    /// The mark's place on the sky, when the cube's WCS is equatorial —
    /// galactic ℓ/b is not a position Search reads.
    func sky(of mark: Mark) -> (ra: Double, dec: Double)? {
        guard mark.anchor.space == .data, let celestial = wcs?.celestial, celestial.frame == .equatorial,
              let sky = celestial.pixelToSky(x: mark.anchor.x, y: mark.anchor.y) else { return nil }
        return (sky.lon, sky.lat)
    }
}

/// What a mark's menu does on the cube viewer.
@MainActor
struct CubeMarkCommands: MarkCommandHost {
    let cube: CubeViewerModel
    let editor: MarkEditor
    let target: MarkStore.Target
    let search: (Double, Double) -> Void

    func canLocateOnSky(_ mark: Mark) -> Bool { cube.sky(of: mark) != nil }

    func perform(_ command: MarkCommand, on mark: Mark) {
        switch command {
        case .editLabel:
            editor.beginNaming(mark.id, on: target)
        case .copyPosition:
            if PlatformClipboard.copy(MarkSummary.clipboardText(mark, sky: cube.sky(of: mark))) {
                cube.toast = String(localized: "Position copied")
            }
        case .centre:
            editor.select(mark.id, on: target)
            cube.centreSlice(onVoxel: mark.anchor.x, mark.anchor.y, channel: Int(mark.anchor.z.rounded()))
        case .searchHere:
            if let sky = cube.sky(of: mark) { search(sky.ra, sky.dec) }
        case .exportFigure:
            break   // not offered: a cube figure is of the whole slice or volume
        case .export(let format):
            export(format)
        case .delete:
            editor.delete(mark.id, on: target)
        }
    }

    func export(_ format: MarkExport.Format) {
        #if os(macOS)
        if let message = MarkExportPanel.save(editor.store.marks(on: target), of: target.file, hdu: nil, as: format) {
            cube.toast = message
        }
        #endif
    }
}
