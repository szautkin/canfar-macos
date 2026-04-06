// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSRenderControlsView: View {
    var model: FITSViewerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stretch
            VStack(alignment: .leading, spacing: 4) {
                Text("Stretch")
                    .font(.caption.bold())
                Picker("", selection: Bindable(model).renderParams.stretch) {
                    ForEach(FITSRenderParams.StretchMode.allCases) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.renderParams.stretch) { _, _ in model.renderImage() }
            }

            // Colormap
            VStack(alignment: .leading, spacing: 4) {
                Text("Colormap")
                    .font(.caption.bold())
                Picker("", selection: Bindable(model).renderParams.colormap) {
                    ForEach(FITSRenderParams.ColormapType.allCases) { cm in
                        Text(cm.rawValue.capitalized).tag(cm)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: model.renderParams.colormap) { _, _ in model.renderImage() }
            }

            // Min/Max cuts
            VStack(alignment: .leading, spacing: 4) {
                Text("Cuts")
                    .font(.caption.bold())
                HStack {
                    Text("Min")
                        .font(.caption2)
                        .frame(width: 30)
                    TextField("", value: Bindable(model).renderParams.minCut, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                        .onSubmit { model.renderImage() }
                }
                HStack {
                    Text("Max")
                        .font(.caption2)
                        .frame(width: 30)
                    TextField("", value: Bindable(model).renderParams.maxCut, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                        .onSubmit { model.renderImage() }
                }
                Button("Auto Cut") {
                    let cuts = FITSParser.autoCut(pixels: model.pixels)
                    model.renderParams.minCut = cuts.min
                    model.renderParams.maxCut = cuts.max
                    model.renderImage()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.pixels.isEmpty)
            }

            // Zoom
            VStack(alignment: .leading, spacing: 4) {
                Text("Zoom")
                    .font(.caption.bold())
                Picker("", selection: Bindable(model).viewport.zoom) {
                    Text("25%").tag(0.25)
                    Text("50%").tag(0.5)
                    Text("100%").tag(1.0)
                    Text("200%").tag(2.0)
                    Text("400%").tag(4.0)
                    Text("800%").tag(8.0)
                    Text("1200%").tag(12.0)
                }
                .pickerStyle(.menu)
                HStack {
                    Button("Fit") {
                        // Approximate fit using a typical canvas size
                        model.fitToWindow(canvasSize: CGSize(width: 800, height: 600))
                    }
                    Button("1:1") { model.viewport.zoom = 1.0 }
                    if model.wcs != nil {
                        Button("N") { model.applyNorthUp() }
                            .help("North Up")
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
    }
}
