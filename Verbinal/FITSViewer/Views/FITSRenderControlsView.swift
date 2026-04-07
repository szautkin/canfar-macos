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
                HStack(spacing: 4) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { level in
                        Button(zoomLabel(level)) {
                            model.viewport.zoom = level
                            model.onZoomChanged?()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.caption2)
                    }
                }
                HStack {
                    Button("Fit") {
                        model.fitToWindow(canvasSize: model.lastCanvasSize)
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

    private func zoomLabel(_ level: Double) -> String {
        if level >= 1 { return "\(Int(level * 100))%" }
        return "\(Int(level * 100))%"
    }
}
