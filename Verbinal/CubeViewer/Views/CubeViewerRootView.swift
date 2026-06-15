// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Root of the Cube Viewer feature — its own landing-tile destination, fully
/// separate from the FITS viewer. Owns one `CubeViewerModel` and opens a cube
/// either from the file picker or from a URL handed in via `AppState`.
struct CubeViewerRootView: View {
    @Environment(AppState.self) private var appState
    @State private var model = CubeViewerModel()

    var body: some View {
        Group {
            if model.isLoading {
                loadingView
            } else if model.hasData {
                CubeViewerView(model: model)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { errorBanner }
        .task(id: appState.pendingCubeURL) {
            guard let url = appState.pendingCubeURL else { return }
            appState.pendingCubeURL = nil
            await model.open(url: url)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Cube Viewer", systemImage: "cube.transparent")
        } description: {
            Text("Open a FITS spectral cube to explore it as native-resolution slices and a GPU-rendered 3D volume.")
        } actions: {
            #if os(macOS)
            Button("Open Cube…") {
                Task { await model.openWithPicker() }
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.loadProgress) {
                Text(model.loadStage).font(.caption.monospaced())
            }
            .frame(width: 260)
            Text(model.fileName).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = model.loadError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.callout).lineLimit(2)
                Spacer()
                Button("Dismiss") { model.loadError = nil }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
