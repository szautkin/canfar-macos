// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a mark's menu does on the FITS viewer.
@MainActor
struct FITSMarkCommands: MarkCommandHost {
    let tab: FITSViewerModel
    let editor: MarkEditor
    let target: MarkStore.Target
    /// Where to say what happened.
    let say: (String) -> Void

    /// The mark's place on the sky: its own, or its pixel through the WCS.
    func sky(of mark: Mark) -> (ra: Double, dec: Double)? {
        switch mark.anchor.space {
        case .sky: return (mark.anchor.x, mark.anchor.y)
        case .imagePixel, .data: return tab.wcs.map { $0.pixelToWorld(x: mark.anchor.x, y: mark.anchor.y) }
        }
    }

    func canLocateOnSky(_ mark: Mark) -> Bool { sky(of: mark) != nil }

    func perform(_ command: MarkCommand, on mark: Mark) {
        switch command {
        case .editLabel:
            editor.beginNaming(mark.id, on: target)
        case .copyPosition:
            if PlatformClipboard.copy(MarkSummary.clipboardText(mark, sky: sky(of: mark))) {
                say(String(localized: "Position copied"))
            }
        case .centre:
            editor.select(mark.id, on: target)
            if let point = tab.displayPoint(mark.anchor) { tab.centerOnPixel(point, canvasSize: tab.lastCanvasSize) }
        case .searchHere:
            if let sky = sky(of: mark) { tab.onSearchAtPosition?(sky.ra, sky.dec) }
        case .export(let format):
            export(format)
        case .delete:
            editor.delete(mark.id, on: target)
        }
    }

    func export(_ format: MarkExport.Format) {
        #if os(macOS)
        if let message = MarkExportPanel.save(editor.store.marks(on: target), of: target.file, hdu: target.hdu, as: format) {
            say(message)
        }
        #endif
    }
}
