// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// Coarse SwiftUI gradient stops sampled from a colormap LUT — shared by
/// the FITS and Cube control panels (swatch grids, colorbars, export
/// legends) so their previews can't drift from the real render.
func colormapPreviewStops(_ cm: FITSRenderParams.ColormapType) -> [Color] {
    let lut = FITSRenderEngine.colormapRGBA(cm)
    return stride(from: 0, to: 256, by: 16).map { i in
        Color(.sRGB,
              red: Double(lut[i * 4]) / 255,
              green: Double(lut[i * 4 + 1]) / 255,
              blue: Double(lut[i * 4 + 2]) / 255)
    }
}

/// The one colormap chooser for both viewers: a grid of gradient swatches
/// (what a colormap looks like IS the choice — a text menu made users
/// memorize names). Selection ring in accent; hairline `.quaternary`
/// borders so unselected swatches read in dark mode.
struct ColormapSwatchGrid: View {
    @Binding var selection: FITSRenderParams.ColormapType
    /// Fired after the binding updates — hosts hang re-renders here.
    var onChange: (() -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 4)], spacing: 4) {
            ForEach(FITSRenderParams.ColormapType.allCases) { cm in
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: colormapPreviewStops(cm),
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                selection == cm ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                lineWidth: selection == cm ? 2 : 1)
                    )
                    .help(cm.rawValue.capitalized)
                    .accessibilityLabel(Text(verbatim: cm.rawValue.capitalized))
                    .accessibilityAddTraits(selection == cm ? [.isButton, .isSelected] : .isButton)
                    .onTapGesture {
                        selection = cm
                        onChange?()
                    }
            }
        }
    }
}
