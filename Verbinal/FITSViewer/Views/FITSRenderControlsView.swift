// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSRenderControlsView: View {
    var model: FITSViewerModel
    @State private var goToRA: String = ""
    @State private var goToDec: String = ""
    @Environment(\.fitsToast) private var toast

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
                .onChange(of: model.renderParams.stretch) { _, _ in model.renderImageDebounced() }
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
                .onChange(of: model.renderParams.colormap) { _, _ in model.renderImageDebounced() }
            }

            // Min/Max cuts
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Cuts")
                        .font(.caption.bold())
                    if model.isRendering {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    }
                }
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Min")
                            .font(.caption2)
                            .frame(width: 28, alignment: .trailing)
                        Slider(
                            value: Bindable(model).renderParams.minCut,
                            in: cutRange
                        )
                        .onChange(of: model.renderParams.minCut) { _, _ in model.renderImageDebounced() }
                        TextField("", value: Bindable(model).renderParams.minCut, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 60)
                            .onSubmit { model.renderImage() }
                    }
                    HStack(spacing: 4) {
                        Text("Max")
                            .font(.caption2)
                            .frame(width: 28, alignment: .trailing)
                        Slider(
                            value: Bindable(model).renderParams.maxCut,
                            in: cutRange
                        )
                        .onChange(of: model.renderParams.maxCut) { _, _ in model.renderImageDebounced() }
                        TextField("", value: Bindable(model).renderParams.maxCut, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 60)
                            .onSubmit { model.renderImage() }
                    }
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

            // Crosshair & Coordinates
            VStack(alignment: .leading, spacing: 6) {
                Text("Crosshair")
                    .font(.caption.bold())

                // Current crosshair display
                if model.crosshairPixel != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "scope")
                                .font(.caption2).foregroundStyle(.red)
                            Text("RA:").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(model.crosshairRA)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 4) {
                            Text("     Dec:").font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(model.crosshairDec)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !model.crosshairValue.isEmpty {
                            HStack(spacing: 4) {
                                Text("     Val:").font(.caption2.bold()).foregroundStyle(.secondary)
                                Text(model.crosshairValue)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                        }
                    }
                    HStack(spacing: 4) {
                        #if os(macOS)
                        Button("Copy") {
                            model.copyCoordsToClipboard()
                            toast?.show("Coordinates copied")
                        }
                        #endif
                        Button("Clear") { model.clearCrosshair() }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Text("Click on image to place crosshair")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Issue 6: out-of-bounds linked crosshair warning
                if model.crosshairOutOfBounds {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Linked position outside image", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        if !model.outOfBoundsRA.isEmpty {
                            HStack(spacing: 4) {
                                Text("RA:").font(.caption2.bold()).foregroundStyle(.secondary)
                                Text(model.outOfBoundsRA)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                            HStack(spacing: 4) {
                                Text("Dec:").font(.caption2.bold()).foregroundStyle(.secondary)
                                Text(model.outOfBoundsDec)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                // Go To coordinates
                if model.wcs != nil {
                    Divider()
                    Text("Go To (degrees)")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("RA", text: $goToRA)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption2, design: .monospaced))
                        TextField("Dec", text: $goToDec)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption2, design: .monospaced))
                        Button("Go") {
                            if let ra = Double(goToRA.trimmingCharacters(in: .whitespaces)),
                               let dec = Double(goToDec.trimmingCharacters(in: .whitespaces)) {
                                let inBounds = model.goToCoordinate(ra: ra, dec: dec)
                                if !inBounds {
                                    toast?.show("Coordinates outside image bounds", isError: true)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.caption2)
                    }
                }
            }

            // Zoom
            VStack(alignment: .leading, spacing: 4) {
                Text("Zoom")
                    .font(.caption.bold())
                HStack(spacing: 4) {
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { level in
                        Button(zoomLabel(level)) {
                            model.setZoom(level)
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
                    Button("1:1") { model.setZoom(1.0) }
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

    private var cutRange: ClosedRange<Float> {
        model.pixelMin < model.pixelMax ? model.pixelMin...model.pixelMax : 0...1
    }

    private func zoomLabel(_ level: Double) -> String {
        "\(Int(level * 100))%"
    }
}
