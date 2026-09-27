// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// What a viewer's canvas needs to show and edit marks — the same on the
/// FITS image and the cube slice, which pass only their target and
/// projection.

extension MarkOverlay {
    /// The editor's marks on `target`, as they are being drawn.
    init(editor: MarkEditor, target: MarkStore.Target, projection: MarkProjection) {
        self.init(marks: editor.marks(on: target), selectedID: editor.selectedID(on: target),
                  namingID: editor.naming?.target == target ? editor.naming?.mark.id : nil,
                  projection: projection)
    }
}

/// The naming field over the mark being named, when it is on this canvas.
struct MarkNamingLayer: View {
    let editor: MarkEditor
    let target: MarkStore.Target?
    let projection: MarkProjection?
    let canvas: CGSize

    var body: some View {
        if let naming = editor.naming, naming.target == target, let projection,
           let frame = MarkGeometry.frame(of: naming.mark, in: projection) {
            MarkLabelField(editor: editor)
                .position(MarkLabelField.centre(for: naming.mark, frame: frame, canvas: canvas))
        }
    }
}

#if os(macOS)
extension ScrollCaptureNSView.Pointer {
    /// The marks' say over a canvas: press, drag, release, double-click to
    /// rename, right-click for the mark's menu, Delete and Escape. The
    /// projection is asked at each event, because the view moves.
    @MainActor
    static func marks(_ editor: MarkEditor, on target: MarkStore.Target, host: MarkCommandHost,
                      projection: @escaping () -> MarkProjection?,
                      emptyDoubleClick: (() -> Void)? = nil) -> Self {
        let hit = { (point: CGPoint) -> Mark? in
            projection().flatMap { MarkGeometry.mark(at: point, in: editor.marks(on: target), projection: $0) }
        }
        return Self(
            press: { point in projection().map { editor.press(at: point, on: target, projection: $0) } ?? false },
            drag: { point in if let p = projection() { editor.drag(to: point, projection: p) } },
            release: { editor.release() },
            doubleClick: { point in
                if let mark = hit(point) {
                    editor.beginNaming(mark.id, on: target)
                    return true
                }
                guard let emptyDoubleClick else { return false }
                emptyDoubleClick()
                return true
            },
            menu: { point in
                guard let mark = hit(point) else { return nil }
                editor.select(mark.id, on: target)
                return MarkMenuItem.menu(for: mark, host: host)
            },
            key: { key in
                switch key {
                case .delete: return editor.deleteSelected(on: target)
                case .escape: return editor.escape(on: target)
                }
            },
            drawing: editor.drawArmed)
    }
}
#endif
