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
                modePicker
                Divider()
                content
            }
            Divider()
            CubeRenderControlsView(model: model)
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
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.viewMode {
        case .slice:
            CubeSliceView(model: model)
        case .volume:
            #if os(macOS)
            CubeVolumeView(model: model)
                .background(Color.black)
            #else
            ContentUnavailableView("Volume mode requires macOS", systemImage: "cube.transparent")
            #endif
        }
    }
}
