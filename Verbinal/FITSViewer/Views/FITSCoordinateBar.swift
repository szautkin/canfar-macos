// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSCoordinateBar: View {
    var model: FITSViewerModel

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

            Text(String(format: "%.0f%%", model.viewport.zoom * 100))
                .font(.caption2)
                .foregroundStyle(.tertiary)

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
