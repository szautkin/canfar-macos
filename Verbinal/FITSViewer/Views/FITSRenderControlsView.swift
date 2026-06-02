// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

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
                    Spacer()
                    Button("Auto") {
                        let cuts = FITSParser.autoCut(pixels: model.pixels)
                        model.renderParams.minCut = cuts.min
                        model.renderParams.maxCut = cuts.max
                        model.renderImage()
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(model.pixels.isEmpty)
                    .help("Auto-stretch using median + sigma clipping")
                }
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Slider(
                            value: Bindable(model).renderParams.minCut,
                            in: cutRange
                        )
                        .onChange(of: model.renderParams.minCut) { _, _ in model.renderImageDebounced() }
                        TextField("", value: Bindable(model).renderParams.minCut, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 80)
                            .onSubmit { model.renderImage() }
                        Stepper("", value: Bindable(model).renderParams.minCut, in: cutRange, step: cutStep)
                            .labelsHidden()
                            .controlSize(.mini)
                            .onChange(of: model.renderParams.minCut) { _, _ in model.renderImageDebounced() }
                    }
                    HStack(spacing: 4) {
                        Text("Max")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Slider(
                            value: Bindable(model).renderParams.maxCut,
                            in: cutRange
                        )
                        .onChange(of: model.renderParams.maxCut) { _, _ in model.renderImageDebounced() }
                        TextField("", value: Bindable(model).renderParams.maxCut, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 80)
                            .onSubmit { model.renderImage() }
                        Stepper("", value: Bindable(model).renderParams.maxCut, in: cutRange, step: cutStep)
                            .labelsHidden()
                            .controlSize(.mini)
                            .onChange(of: model.renderParams.maxCut) { _, _ in model.renderImageDebounced() }
                    }
                }
                // Cut window width — helps the astronomer gauge contrast
                HStack {
                    Spacer()
                    Text("Window: \(cutWindow, specifier: "%.1f")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                // Ticket 037: when the loaded image has no usable spread (all
                // pixels identical or all NaN) the slider falls back to 0...1.
                // Explain that rather than letting the range silently misrepresent
                // the data.
                if !model.pixels.isEmpty && model.pixelRangeDegenerate {
                    Label("Uniform or NaN-only data — showing fallback 0…1 range", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Every finite pixel in this image has the same value (or all pixels are NaN), so there is no data range to map. The cut controls show a 0…1 fallback.")
                }
            }

            // Crosshair & Coordinates
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Crosshair")
                        .font(.caption.bold())
                    if model.wcs?.isApproximate == true {
                        Label("WCS approximate", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("This file lacks standard WCS calibration. Coordinates are estimated from legacy header keywords and may be imprecise.")
                    }
                }

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
                            toast?.show(String(localized: "Coordinates copied"))
                        }
                        #endif
                        Button("Clear") { model.clearCrosshair() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button {
                        model.searchAtCrosshair()
                    } label: {
                        Label("Search Here", systemImage: "location.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.crosshairRADeg == nil)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help(model.wcs != nil ? "Search for observations at this sky position (⌘⇧L)" : "Requires WCS calibration data")
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
                                    toast?.show(String(localized: "Coordinates outside image bounds"), isError: true)
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
        model.pixelRangeDegenerate ? 0...1 : model.pixelMin...model.pixelMax
    }

    /// Current cut window width (maxCut − minCut).
    private var cutWindow: Float {
        max(model.renderParams.maxCut - model.renderParams.minCut, 0)
    }

    /// Stepper increment: 1% of the *current cut window*, not the full pixel range.
    /// As the astronomer narrows the cuts to find faint features, the step auto-refines.
    /// Floor at 0.1 to allow fine control on narrow-band calibration data (window < 10 ADU).
    private var cutStep: Float.Stride {
        let window = cutWindow
        guard window > 0 else { return 1 }
        return Float.Stride(max(window / 100, 0.1))
    }

    private func zoomLabel(_ level: Double) -> String {
        "\(Int(level * 100))%"
    }
}
