// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Render-control side panel. Window/stretch/colormap are shared by both modes
/// (slice re-renders, debounced; volume picks them up live). Density, spectral
/// scale, MIP, and the transfer function apply to the volume mode.
struct CubeRenderControlsView: View {
    @Bindable var model: CubeViewerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                infoSection
                Divider()
                displaySection
                if model.viewMode == .volume {
                    Divider()
                    volumeSection
                }
                #if os(macOS)
                Divider()
                exportSection
                #endif
            }
            .padding(14)
        }
        .frame(width: 270)
    }

    // MARK: Cube info + statistics

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.object.isEmpty, model.object != "—" {
                Text(model.object).font(.headline)
            }
            let meta = [model.telescope, model.instrument].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            infoRow("Dimensions", "\(model.nx) × \(model.ny) × \(model.nz)")
            if !model.bunit.isEmpty { infoRow("Unit", model.bunit) }
            if let stats = model.stats {
                infoRow("Range", "\(fmt(stats.lo)) … \(fmt(stats.hi))")
                infoRow("Min / Max", "\(fmt(stats.min)) / \(fmt(stats.max))")
                infoRow("Median", fmt(stats.median))
                infoRow("NaN", String(format: "%.1f%%", stats.nanFrac * 100))
            }
            infoRow("Mode", model.isStreamed ? "Streamed" : "Resident")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display").font(.subheadline.bold())

            colormapSwatches
            stretchButtons
            windowControl
            colorbar
        }
    }

    private var windowControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Window").font(.caption)
                Spacer()
                let raw = model.rawWindow
                Text("\(fmt(raw.lo)) … \(fmt(raw.hi))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: windowLoBinding, in: 0...1)
            Slider(value: windowHiBinding, in: 0...1)
            HStack(spacing: 6) {
                Button("p99.9") { model.autoWindowPercentile() }
                Button("Min/Max") { model.autoWindowFullRange() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    /// Colorbar legend — the active colormap ramp with raw min/max labels.
    private var colorbar: some View {
        let raw = model.rawWindow
        return VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: colorbarStops, startPoint: .leading, endPoint: .trailing))
                .frame(height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
            HStack {
                Text(fmt(raw.lo)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(fmt(raw.hi)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var colorbarStops: [Color] { stops(for: model.colormap) }

    private func stops(for cm: FITSRenderParams.ColormapType) -> [Color] {
        let lut = FITSRenderEngine.colormapRGBA(cm)
        return stride(from: 0, to: 256, by: 16).map { i in
            Color(.sRGB, red: Double(lut[i * 4]) / 255, green: Double(lut[i * 4 + 1]) / 255, blue: Double(lut[i * 4 + 2]) / 255)
        }
    }

    private var colormapSwatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colormap").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 4)], spacing: 4) {
                ForEach(FITSRenderParams.ColormapType.allCases) { cm in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: stops(for: cm), startPoint: .leading, endPoint: .trailing))
                        .frame(height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(model.colormap == cm ? Color.accentColor : Color.black.opacity(0.15),
                                              lineWidth: model.colormap == cm ? 2 : 1)
                        )
                        .help(cm.rawValue.capitalized)
                        .onTapGesture { model.colormap = cm; model.renderSliceDebounced() }
                }
            }
        }
    }

    private var stretchButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stretch").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4)], spacing: 4) {
                ForEach(FITSRenderParams.StretchMode.allCases) { mode in
                    Button(mode.rawValue.capitalized) {
                        model.stretch = mode; model.renderSliceDebounced()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(model.stretch == mode ? Color.accentColor : nil)
                }
            }
        }
    }

    // MARK: Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume").font(.subheadline.bold())

            Picker("Mode", selection: $model.mip) {
                Text("Emission").tag(false)
                Text("Max-intensity").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !model.mip {
                labeledSlider("Density", value: $model.density, range: 0.1...3)
            }
            labeledSlider("Spectral scale", value: $model.spectralScale, range: 0.5...4)
            labeledSlider("Quality", value: $model.volumeSteps, range: 96...768)

            Toggle("Slice-plane marker", isOn: $model.showSlicePlane)
                .toggleStyle(.switch).controlSize(.small)
            Toggle("Idle auto-orbit", isOn: $model.autoOrbit)
                .toggleStyle(.switch).controlSize(.small)

            if !model.mip {
                Text("Opacity curve").font(.caption).foregroundStyle(.secondary)
                TransferFunctionEditor(points: $model.transferFunction)
            }
        }
    }

    #if os(macOS)
    private var exportSection: some View {
        Menu {
            Button("Figure — PNG 2×") { exportFigure(scale: 2) }
            Button("Figure — PNG 4×") { exportFigure(scale: 4) }
            Divider()
            Button("Slice — raw PNG") { model.exportSlicePNG() }
                .disabled(model.sliceImage == nil)
        } label: {
            Label("Export…", systemImage: "square.and.arrow.down")
        }
    }

    /// Compose a labeled figure plate (title + image + colorbar) and save as PNG.
    /// Slice exports its rendered CGImage; volume captures a fresh GPU snapshot.
    private func exportFigure(scale: CGFloat) {
        let content: CGImage? = model.viewMode == .slice ? model.sliceImage : model.volumeSnapshot?(1280, 960)
        guard let image = content else { return }
        let raw = model.rawWindow
        let subtitle = model.viewMode == .slice
            ? "CH \(model.channel + 1)/\(model.nz)   \(model.spectralReadout?.primary ?? "")"
            : "\(model.nx) × \(model.ny) × \(model.nz)  ·  volume"
        let title = (model.object.isEmpty || model.object == "—")
            ? (model.fileName.isEmpty ? "Cube" : model.fileName) : model.object
        let plate = CubeExportPlate(content: image, title: title, subtitle: subtitle,
                                    stops: colorbarStops, loLabel: fmt(raw.lo), hiLabel: fmt(raw.hi), unit: model.bunit)
        let imageRenderer = ImageRenderer(content: plate)
        imageRenderer.scale = scale
        guard let nsImage = imageRenderer.nsImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let base = (model.object.isEmpty || model.object == "—") ? "cube" : model.object
        panel.nameFieldStringValue = "\(base)_\(model.viewMode == .slice ? "ch\(model.channel + 1)" : "volume").png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
    #endif

    // MARK: Helpers

    @ViewBuilder
    private func labeledSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3g", v) }

    // Slice-affecting bindings re-render the slice (debounced); the volume reads
    // these live via updateNSView, so no extra plumbing there.
    private var windowLoBinding: Binding<Float> {
        Binding(get: { model.windowLo }, set: { model.windowLo = min($0, model.windowHi - 0.01); model.renderSliceDebounced() })
    }
    private var windowHiBinding: Binding<Float> {
        Binding(get: { model.windowHi }, set: { model.windowHi = max($0, model.windowLo + 0.01); model.renderSliceDebounced() })
    }
}

#if os(macOS)
/// Figure-plate layout rendered to an image by `ImageRenderer` for export.
private struct CubeExportPlate: View {
    let content: CGImage
    let title: String
    let subtitle: String
    let stops: [Color]
    let loLabel: String
    let hiLabel: String
    let unit: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)

            Image(decorative: content, scale: 1)
                .resizable()
                .scaledToFit()

            HStack(spacing: 8) {
                Text(loLabel).font(.caption2.monospaced())
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                Text(hiLabel).font(.caption2.monospaced())
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(12)
        }
        .frame(width: 900)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}
#endif
