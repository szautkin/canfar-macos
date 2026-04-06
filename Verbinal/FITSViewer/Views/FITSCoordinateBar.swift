// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSCoordinateBar: View {
    var model: FITSViewerModel
    @State private var zoomText: String = ""
    @FocusState private var zoomFieldFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            if model.wcs != nil {
                HStack(spacing: 4) {
                    Text("RA:")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(model.cursorRA.isEmpty ? "-" : model.cursorRA)
                        .font(.system(.caption2, design: .monospaced))
                }

                HStack(spacing: 4) {
                    Text("Dec:")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Text(model.cursorDec.isEmpty ? "-" : model.cursorDec)
                        .font(.system(.caption2, design: .monospaced))
                }
            }

            HStack(spacing: 4) {
                Text("Value:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(model.cursorPixelValue.isEmpty ? "-" : model.cursorPixelValue)
                    .font(.system(.caption2, design: .monospaced))
            }

            // Crosshair info (if placed)
            if !model.crosshairRA.isEmpty {
                Divider().frame(height: 12)
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("\(model.crosshairRA) \(model.crosshairDec)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                    Text("= \(model.crosshairValue)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            TextField("Zoom", text: $zoomText)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 50)
                .textFieldStyle(.roundedBorder)
                .focused($zoomFieldFocused)
                .onAppear { zoomText = String(format: "%.0f%%", model.viewport.zoom * 100) }
                .onChange(of: model.viewport.zoom) { _, newZoom in
                    if !zoomFieldFocused {
                        zoomText = String(format: "%.0f%%", newZoom * 100)
                    }
                }
                .onSubmit {
                    let cleaned = zoomText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                    if let pct = Double(cleaned), pct > 0 {
                        model.viewport.zoom = max(0.05, min(20, pct / 100.0))
                        model.onZoomChanged?()
                    }
                    zoomText = String(format: "%.0f%%", model.viewport.zoom * 100)
                    zoomFieldFocused = false
                }
                .help("Type zoom percentage and press Enter")

            if let hdu = model.selectedHDU {
                Text("\(hdu.header.naxis1) \u{00d7} \(hdu.header.naxis2)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let wcs = model.wcs {
                    Text(String(format: "%.2f\"/px", wcs.pixelScaleArcsec))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
