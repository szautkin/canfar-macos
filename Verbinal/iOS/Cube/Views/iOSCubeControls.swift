// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Charts
import SwiftUI
import VerbinalKit

/// A cube's controls, in a sheet that leaves it usable (plan 47 5.3, 5.4):
/// how it is shown, a spaxel's spectrum, and whether it is right.
struct iOSCubeControls: View {
    @Bindable var model: CubeViewerModel
    @Binding var section: Section
    @Environment(\.dismiss) private var dismiss

    enum Section: String, CaseIterable, Identifiable {
        case display, spectrum, verify
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .display: return "Display"
            case .spectrum: return "Spectrum"
            case .verify: return "Verify"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                switch section {
                case .display: display
                case .spectrum: iOSCubeSpectrum(model: model)
                case .verify: iOSCubeVerify(model: model)
                }
            }
            .navigationTitle(model.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - Display

    private var display: some View {
        Form {
            SwiftUI.Section("Window") {
                LabeledContent("Low") {
                    Slider(value: $model.windowLo, in: 0...1).onChange(of: model.windowLo) { _, low in
                        if low >= model.windowHi { model.windowLo = max(0, model.windowHi - 0.001) }
                        model.requestSliceRender()
                    }
                }
                LabeledContent("High") {
                    Slider(value: $model.windowHi, in: 0...1).onChange(of: model.windowHi) { _, high in
                        if high <= model.windowLo { model.windowHi = min(1, model.windowLo + 0.001) }
                        model.requestSliceRender()
                    }
                }
            }
            SwiftUI.Section("Stretch") {
                Picker("Stretch", selection: $model.stretch) {
                    ForEach(FITSRenderParams.StretchMode.allCases) { Text(verbatim: $0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.stretch) { _, _ in model.requestSliceRender() }
            }
            SwiftUI.Section("Colormap") {
                Picker("Colormap", selection: $model.colormap) {
                    ForEach(FITSRenderParams.ColormapType.allCases) { Text(verbatim: $0.rawValue.capitalized).tag($0) }
                }
                .onChange(of: model.colormap) { _, _ in model.requestSliceRender() }
            }
            if model.viewMode == .volume {
                SwiftUI.Section("Volume") {
                    LabeledContent("Density") { Slider(value: $model.density, in: 0.1...4) }
                    Toggle("Brightest Along the Ray (MIP)", isOn: $model.mip)
                    Toggle("Show the Channel's Plane", isOn: $model.showSlicePlane)
                }
            }
        }
    }
}

/// A spaxel's spectrum: long-press a spaxel, lift, and it is here. Drag
/// along it to move the channel.
struct iOSCubeSpectrum: View {
    var model: CubeViewerModel

    private var points: [(channel: Int, value: Float)] {
        (model.probeSpectrum ?? []).enumerated().compactMap { $1.isFinite ? ($0, $1) : nil }
    }

    var body: some View {
        if let reason = model.probeUnavailableReason {
            ContentUnavailableView("No Spectrum", systemImage: "waveform.path.ecg", description: Text(verbatim: reason))
        } else if model.probeSpectrum == nil {
            ContentUnavailableView("No Spectrum Yet", systemImage: "hand.tap",
                                   description: Text("Hold a spaxel on the slice, then lift your finger: its spectrum shows here."))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let point = model.probePoint {
                    Text("Spaxel (\(point.x), \(point.y))").font(.caption).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(points, id: \.channel) { point in
                        LineMark(x: .value("Channel", point.channel), y: .value("Value", point.value))
                            .interpolationMethod(.stepCenter)
                    }
                    RuleMark(x: .value("Channel", model.channel))
                        .foregroundStyle(Color.accentColor)
                }
                .chartXAxisLabel("Channel")
                .chartYAxisLabel(model.bunit)
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                if let channel: Int = proxy.value(atX: value.location.x) { model.setChannel(channel) }
                            })
                    }
                }
                .frame(minHeight: 200)
                if let readout = model.spectralReadout {
                    Text(verbatim: [readout.primary, readout.secondary].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit())
                }
            }
            .padding()
        }
    }
}

/// Is it right? The spectral axis, the values, the blank channels (plan 47 5.4).
struct iOSCubeVerify: View {
    var model: CubeViewerModel

    var body: some View {
        List {
            Section("Cube") {
                LabeledContent("Size", value: "\(model.nx) × \(model.ny) × \(model.nz)")
                if !model.object.isEmpty { LabeledContent("OBJECT", value: model.object) }
                if !model.telescope.isEmpty { LabeledContent("TELESCOP", value: model.telescope) }
                if !model.instrument.isEmpty { LabeledContent("INSTRUME", value: model.instrument) }
                if !model.bunit.isEmpty { LabeledContent("BUNIT", value: model.bunit) }
                if model.isStreamed {
                    Label("Too large to hold: its slices are read from the file as needed.", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let spectral = model.wcs?.spectral {
                Section("Spectral Axis") {
                    LabeledContent("CTYPE3", value: spectral.ctype.isEmpty ? "—" : spectral.ctype)
                    if !spectral.cunit.isEmpty { LabeledContent("CUNIT3", value: spectral.cunit) }
                    LabeledContent("First", value: spectral.format(channel: 0).primary)
                    LabeledContent("Last", value: spectral.format(channel: max(model.nz - 1, 0)).primary)
                    LabeledContent("Step (CDELT3)", value: spectral.cdelt.formatted(.number.precision(.significantDigits(1...6))))
                    if let rest = spectral.restfrq {
                        LabeledContent("RESTFRQ", value: "\((rest / 1e9).formatted(.number.precision(.significantDigits(1...9)))) GHz")
                    }
                }
            }
            if let stats = model.stats {
                Section("Values") {
                    LabeledContent("Min", value: iOSFITSDisplayPanel.cut(stats.min))
                    LabeledContent("Max", value: iOSFITSDisplayPanel.cut(stats.max))
                    LabeledContent(model.isStreamed ? LocalizedStringKey("Median (sampled)") : LocalizedStringKey("Median"),
                                   value: iOSFITSDisplayPanel.cut(stats.median))
                    LabeledContent("Blank (NaN)", value: (Double(stats.nanFrac)).formatted(.percent.precision(.fractionLength(1))))
                    if let profile = model.channelProfile {
                        let blank = profile.filter { !$0.isFinite }.count
                        LabeledContent("Blank Channels", value: "\(blank) / \(profile.count)")
                    }
                }
            }
        }
        .monospacedDigit()
    }
}
