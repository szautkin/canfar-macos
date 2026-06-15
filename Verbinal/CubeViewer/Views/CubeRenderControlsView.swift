// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// Render-control side panel. Window/stretch/colormap are shared by both modes
/// (slice re-renders, debounced; volume picks them up live). Density, spectral
/// scale, MIP, and the transfer function apply to the volume mode.
struct CubeRenderControlsView: View {
    @Bindable var model: CubeViewerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metadataSection
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

    // MARK: Sections

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.object.isEmpty, model.object != "—" {
                Text(model.object).font(.headline)
            }
            Text("\(model.nx) × \(model.ny) × \(model.nz)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            let meta = [model.telescope, model.instrument].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            if model.isStreamed {
                Label("Streamed", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display").font(.subheadline.bold())

            Picker("Colormap", selection: colormapBinding) {
                ForEach(FITSRenderParams.ColormapType.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }

            Picker("Stretch", selection: stretchBinding) {
                ForEach(FITSRenderParams.StretchMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }

            labeledSlider("Black point", value: windowLoBinding, range: 0...1)
            labeledSlider("White point", value: windowHiBinding, range: 0...1)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume").font(.subheadline.bold())

            Toggle("Maximum intensity (MIP)", isOn: $model.mip)
                .toggleStyle(.switch)
                .controlSize(.small)

            if !model.mip {
                labeledSlider("Density", value: $model.density, range: 0.1...3)
            }
            labeledSlider("Spectral scale", value: $model.spectralScale, range: 0.5...4)

            if !model.mip {
                Text("Opacity curve").font(.caption).foregroundStyle(.secondary)
                TransferFunctionEditor(points: $model.transferFunction)
            }
        }
    }

    #if os(macOS)
    private var exportSection: some View {
        Button {
            model.exportSlicePNG()
        } label: {
            Label("Export slice as PNG…", systemImage: "square.and.arrow.down")
        }
        .disabled(model.sliceImage == nil)
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

    // Slice-affecting bindings re-render the slice (debounced); the volume reads
    // these live via updateNSView, so no extra plumbing there.
    private var colormapBinding: Binding<FITSRenderParams.ColormapType> {
        Binding(get: { model.colormap }, set: { model.colormap = $0; model.renderSliceDebounced() })
    }
    private var stretchBinding: Binding<FITSRenderParams.StretchMode> {
        Binding(get: { model.stretch }, set: { model.stretch = $0; model.renderSliceDebounced() })
    }
    private var windowLoBinding: Binding<Float> {
        Binding(get: { model.windowLo }, set: { model.windowLo = min($0, model.windowHi - 0.01); model.renderSliceDebounced() })
    }
    private var windowHiBinding: Binding<Float> {
        Binding(get: { model.windowHi }, set: { model.windowHi = max($0, model.windowLo + 0.01); model.renderSliceDebounced() })
    }
}
