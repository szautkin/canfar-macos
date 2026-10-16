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

// Colormap gradient stops + the swatch grid live in
// Helpers/ColormapSwatches.swift, shared with the FITS panel.

/// Render-control side panel. Window/stretch/colormap are shared by both modes
/// (slice re-renders coalesced; volume picks them up live). Density, spectral
/// scale, MIP, and the transfer function apply to the volume mode.
struct CubeRenderControlsView: View {
    @Bindable var model: CubeViewerModel
    var marks: MarkEditor?
    var markCommands: MarkCommandHost?
    @State private var showExport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoSection
                Divider()
                displaySection
                if model.viewMode == .volume {
                    Divider()
                    volumeSection
                }
                if let marks {
                    Divider()
                    MarksPanel(editor: marks, target: model.markTarget, host: markCommands)
                }
                #if os(macOS)
                Divider()
                exportSection
                #endif
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No fixed width — the host HSplitView bounds the panel
        // (min 240 / ideal 270 / max 340), matching the FITS sidebar.
        #if os(macOS)
        .uiPresented("Export Cube Figure", .sheet, isPresented: $showExport)
        .sheet(isPresented: $showExport) {
            CubeExportView(model: model, marks: model.markTarget.map { marks?.marks(on: $0) ?? [] } ?? [])
        }
        #endif
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
            Text("Display").font(.subheadline.weight(.semibold))

            colormapSwatches
            stretchButtons
            windowControl
            colorbar
            // Segments where they fit, a menu where they do not: a row wider
            // than the panel pushed all of it off both edges (2026-10-15).
            ViewThatFits(in: .horizontal) {
                backgroundPicker.pickerStyle(.segmented)
                backgroundPicker.pickerStyle(.menu)
            }
        }
    }

    private var backgroundPicker: some View {
        Picker("Background", selection: $model.background) {
            ForEach(CubeBackground.allCases) { Text($0.label).tag($0) }
        }
    }

    private var windowControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Window").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let raw = model.rawWindow
                Text("\(fmt(raw.lo)) … \(fmt(raw.hi))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("Low")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Slider(value: windowLoBinding, in: 0...1)
                    .accessibilityLabel("Window low")
            }
            HStack(spacing: 4) {
                Text("High")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Slider(value: windowHiBinding, in: 0...1)
                    .accessibilityLabel("Window high")
            }
            HStack(spacing: 6) {
                Button("Auto") { model.autoWindow() }
                    .help("A little below the background to where the brightest percent begins")
                Button("99.9%") { model.autoWindowPercentile() }
                Button("Full Range") { model.autoWindowFullRange() }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    private var colorbarStops: [Color] { colormapPreviewStops(model.colormap) }

    private var colormapSwatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colormap").font(.caption).foregroundStyle(.secondary)
            ColormapSwatchGrid(
                selection: Bindable(model).colormap,
                onChange: { model.requestSliceRender() }
            )
        }
    }

    /// Segmented, matching the FITS panel — one single-choice affordance
    /// for the same concept across both viewers. Five segments need about
    /// 290 points and cannot shrink, and the panel gives its content 208 to
    /// 308: a menu when they do not fit, as the FITS panel's is — wider than
    /// the panel, they pushed all of it off both edges (2026-10-15).
    private var stretchButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stretch").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                stretchPicker.pickerStyle(.segmented)
                stretchPicker.pickerStyle(.menu)
            }
            .labelsHidden()
        }
    }

    private var stretchPicker: some View {
        Picker("Stretch", selection: Binding(
            get: { model.stretch },
            set: { model.stretch = $0; model.requestSliceRender() }
        )) {
            ForEach(FITSRenderParams.StretchMode.allCases) { mode in
                Text(mode.rawValue.capitalized).tag(mode)
            }
        }
    }

    // MARK: Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume").font(.subheadline.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                volumeModePicker.pickerStyle(.segmented)
                volumeModePicker.pickerStyle(.menu)
            }
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

    private var volumeModePicker: some View {
        Picker("Mode", selection: $model.mip) {
            Text("Emission").tag(false)
            Text("Max Intensity").tag(true)
        }
    }

    #if os(macOS)
    private var exportSection: some View {
        Button { showExport = true } label: {
            Label("Export Figure…", systemImage: "square.and.arrow.up")
        }
        .opens("Export Cube Figure")
    }
    #endif

    // MARK: Helpers

    @ViewBuilder
    private func labeledSlider(_ title: LocalizedStringKey, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func infoRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Float) -> String { String(format: "%.3g", v) }

    // Slice-affecting bindings re-render the slice (coalesced); the volume reads
    // these live via updateNSView, so no extra plumbing there.
    private var windowLoBinding: Binding<Float> {
        Binding(get: { model.windowLo }, set: { model.windowLo = min($0, model.windowHi - 0.01); model.requestSliceRender() })
    }
    private var windowHiBinding: Binding<Float> {
        Binding(get: { model.windowHi }, set: { model.windowHi = max($0, model.windowLo + 0.01); model.requestSliceRender() })
    }
}
