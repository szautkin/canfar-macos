// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Root of the Cube Viewer feature — its own landing-tile destination, fully
/// separate from the FITS viewer. Owns one `CubeViewerModel` and opens a cube
/// from the file picker, a dropped file, or a URL handed in via `AppState`.
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
        .overlay(alignment: .bottom) { toastView }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.open(url: url) }
            return true
        }
        .sheet(isPresented: Binding(get: { model.showGuide }, set: { model.showGuide = $0 })) {
            CubeGuideView()
        }
        .task(id: appState.pendingCubeURL) {
            guard let url = appState.pendingCubeURL else { return }
            appState.pendingCubeURL = nil
            await model.open(url: url)
        }
        .task(id: model.toast) {
            guard model.toast != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { model.toast = nil }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Cube Viewer", systemImage: "cube.transparent")
        } description: {
            Text("Open or drop a FITS spectral cube to explore it as native-resolution slices and a GPU-rendered 3D volume.")
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

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .padding(.bottom, 24)
                .shadow(radius: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Operating guide sheet — workflow, the slice/volume contract, and key map.
private struct CubeGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Cube Viewer Guide").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("The loop", [
                        "Open a cube — the tile, drag-and-drop, or the AI agent.",
                        "Scrub channels in Slice; tune Window + Stretch for contrast.",
                        "Switch to Volume for 3D structure; shape opacity with the transfer function.",
                        "Click a feature in Volume to jump to its brightest channel.",
                    ])
                    section("Slice vs Volume", [
                        "Slice = quantitative: true voxel values with WCS + spectral readouts.",
                        "Volume = qualitative: GPU ray-march, emission or max-intensity.",
                    ])
                    section("Keys", [
                        "← / →  channel (Shift = ±10)",
                        "Space  play / pause",
                        "V  toggle slice ⇆ volume",
                        "R  reset window",
                    ])
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { item in
                Text("•  \(item)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
