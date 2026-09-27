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
