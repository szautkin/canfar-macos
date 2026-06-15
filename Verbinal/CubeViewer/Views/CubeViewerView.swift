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
            .background(Color.black)
            #else
            ContentUnavailableView("Volume mode requires macOS", systemImage: "cube.transparent")
            #endif
        }
    }
}
