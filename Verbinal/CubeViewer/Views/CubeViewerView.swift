// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The loaded-cube layout: a mode switch (Slice ⇆ Volume) over the active view,
/// with the render-control side panel.
struct CubeViewerView: View {
    @Bindable var model: CubeViewerModel
    @Environment(AppState.self) private var appState

    private var marks: MarkEditor { appState.cubeMarkEditor }

    /// What a mark's menu does here; nil before a cube is open.
    private var markCommands: CubeMarkCommands? {
        model.markTarget.map {
            CubeMarkCommands(cube: model, editor: marks, target: $0, search: { [weak appState] ra, dec in
                appState?.dispatch(.searchCoordinates(ra: ra, dec: dec))
            })
        }
    }

    var body: some View {
        // HSplitView so the control panel is user-resizable within the
        // same bounds idiom as the FITS sidebar — the two viewers' side
        // panels must feel like the same piece of furniture. (Previously
        // the cube panel was a hard fixed width.)
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    modePicker
                    Spacer()
                    Button {
                        model.showSpectrumPanel.toggle()
                    } label: {
                        Label("Spectrum", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(.borderless)
                    .help("Show or hide spectrum inspector")
                    Button { model.showGuide = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Cube Viewer guide")
                    .accessibilityLabel("Cube Viewer guide")
                }
                .padding(.horizontal, 8)
                Divider()
                content
                if model.showSpectrumPanel {
                    Divider()
                    spectrumPanel
                }
                Divider()
                timelineBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            CubeRenderControlsView(model: model, marks: marks, markCommands: markCommands)
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
    }

    private var spectrumPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spectrum")
                .font(.caption.bold())
            if let spectrum = model.probeSpectrum, !spectrum.isEmpty {
                Text("Pixel (\(model.probePoint?.x ?? 0), \(model.probePoint?.y ?? 0)) · \(spectrum.count) channels")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Click a spatial pixel in Slice mode to inspect its spectrum.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Keyboard: ←/→ scrub (Shift = ±10), Space play/pause, V toggle mode,
    /// R reset window. Mirrors v-cube's key map.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let target = model.markTarget {
            switch press.key {
            case .delete, .deleteForward:
                if marks.deleteSelected(on: target) { return .handled }
            case .escape:
                if marks.escape(on: target) { return .handled }
            default:
                break
            }
        }
        switch press.key {
        case .leftArrow:
            model.stepChannel(press.modifiers.contains(.shift) ? -10 : -1); return .handled
        case .rightArrow:
            model.stepChannel(press.modifiers.contains(.shift) ? 10 : 1); return .handled
        case .space:
            model.togglePlayback(); return .handled
        default:
            break
        }
        switch press.characters {
        case "v":
            model.viewMode = model.viewMode == .slice ? .volume : .slice; return .handled
        case "r":
            model.autoWindow(); return .handled
        default:
            return .ignored
        }
    }

    private var modePicker: some View {
        Picker("", selection: $model.viewMode) {
            ForEach(CubeViewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .padding(.vertical, 8)
    }

    /// Channel timeline — shared by both modes. In volume mode, scrubbing moves
    /// the slice-plane marker and updates the spectral readout.
    private var timelineBar: some View {
        HStack(spacing: 12) {
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(model.isPlaying ? "Pause (Space)" : "Play through channels (Space)")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            .disabled(model.nz <= 1)

            Button { model.stepChannel(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(model.channel <= 0)
                .help("Previous channel (←)")
                .accessibilityLabel("Previous channel")

            ChannelScrubber(profile: model.channelProfile, channel: model.channel, count: model.nz) {
                model.setChannel($0)
            }

            Button { model.stepChannel(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(model.channel >= model.nz - 1)
                .help("Next channel (→)")
                .accessibilityLabel("Next channel")

            if let readout = model.spectralReadout {
                Text(readout.primary)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .trailing)
            }
            Text("\(model.channel + 1) / \(model.nz)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.viewMode {
        case .slice:
            CubeSliceView(model: model, marks: marks, search: { [weak appState] ra, dec in
                appState?.dispatch(.searchCoordinates(ra: ra, dec: dec))
            })
        case .volume:
            #if os(macOS)
            ZStack(alignment: .top) {
                CubeVolumeView(model: model)
                if let target = model.markTarget {
                    GeometryReader { geo in
                        if let projection = model.volumeMarkProjection(canvasSize: geo.size) {
                            MarkOverlay(editor: marks, target: target, projection: projection, showsGrips: false)
                        }
                    }
                    .allowsHitTesting(false)
                }
                CubeAxisCaptions(model: model)
                if let error = model.volumeRenderError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.92))
                }
            }
            .background(model.background.color)
            #else
            ContentUnavailableView("Volume mode requires macOS", systemImage: "cube.transparent")
            #endif
        }
    }
}

extension CubeBackground {
    /// SwiftUI bridge for the model's SwiftUI-free `rgba`.
    var color: Color {
        Color(.sRGB, red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: Double(rgba.w))
    }
}
