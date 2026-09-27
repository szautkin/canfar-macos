// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The field a mark is named in, over the mark itself. Return keeps the
/// words, Escape leaves the mark as it was, the bin deletes it.
struct MarkLabelField: View {
    @Bindable var editor: MarkEditor
    @FocusState private var focused: Bool

    static let width: CGFloat = 220

    var body: some View {
        HStack(spacing: 4) {
            TextField("Label", text: $editor.namingText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { editor.commitNaming() }
                #if os(macOS)
                .onExitCommand { editor.cancelNaming() }
                #endif
                .accessibilityLabel(Text("Mark label"))
            Button { editor.commitNaming() } label: { Image(systemName: "checkmark") }
                .help("Keep the label")
                .accessibilityLabel(Text("Keep the label"))
            Button(role: .destructive) { editor.deleteNaming() } label: { Image(systemName: "trash") }
                .help("Delete the mark")
                .accessibilityLabel(Text("Delete the mark"))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(4)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .onAppear { focused = true }
    }

    /// Where the field goes: over the mark's words (below a mark without
    /// any), kept inside the canvas so it can be typed in.
    static func centre(for mark: Mark, frame: MarkGeometry.Frame, canvas: CGSize) -> CGPoint {
        let wanted: CGPoint
        if mark.kind == .callout || mark.kind == .text,
           let words = MarkGeometry.label(of: mark, frame: frame, always: true)?.box {
            wanted = CGPoint(x: words.minX + width / 2 - 8, y: words.midY)
        } else {
            wanted = CGPoint(x: frame.centre.x, y: frame.centre.y + frame.half.height + 22)
        }
        let half = width / 2 + 4
        let x = min(max(wanted.x, half), max(canvas.width - half, half))
        let y = min(max(wanted.y, 20), max(canvas.height - 20, 20))
        return CGPoint(x: x, y: y)
    }
}
