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

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    modePicker
                    Spacer()
                    Button { model.showGuide = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Cube Viewer guide")
                }
                .padding(.horizontal, 8)
                Divider()
                content
                Divider()
                timelineBar
            }
            Divider()
            CubeRenderControlsView(model: model)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
    }

    /// Keyboard: ←/→ scrub (Shift = ±10), Space play/pause, V toggle mode,
    /// R reset window. Mirrors v-cube's key map.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
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
            model.autoWindowPercentile(); return .handled
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
            .disabled(model.nz <= 1)

            Button { model.stepChannel(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(model.channel <= 0)

            ChannelScrubber(profile: model.channelProfile, channel: model.channel, count: model.nz) {
                model.setChannel($0)
            }

            Button { model.stepChannel(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(model.channel >= model.nz - 1)

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
            CubeSliceView(model: model)
        case .volume:
            #if os(macOS)
            ZStack {
                CubeVolumeView(model: model)
                CubeAxisCaptions(model: model)
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
