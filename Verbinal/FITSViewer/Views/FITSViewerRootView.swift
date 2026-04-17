// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSViewerRootView: View {
    @Environment(AppState.self) private var appState
    @State private var tabHost = FITSTabHostModel()
    @State private var toastManager = ToastManager()

    var body: some View {
        Group {
            if tabHost.tabs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "star.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("FITS Viewer")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Open a FITS file to view astronomical images.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    #if os(macOS)
                    Button("Open FITS File") {
                        let model = tabHost.addTab()
                        Task { await model.openWithPicker() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("Open a FITS file")
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FITSTabView(tabHost: tabHost)
            }
        }
        .environment(\.fitsToast, toastManager)
        .toast(toastManager)
        .task(id: appState.pendingFITSURL) {
            guard let url = appState.pendingFITSURL else { return }
            appState.pendingFITSURL = nil
            await tabHost.openFile(url: url)
        }
        .onChange(of: tabHost.activeTab?.pendingToast) { _, message in
            guard let message else { return }
            toastManager.show(message)
            tabHost.activeTab?.pendingToast = nil
        }
        // Wire "Search at Position" callback for every tab so the FITS viewer
        // crosshair button and context menu can dispatch to the Search module.
        .onChange(of: tabHost.tabs.count) { _, _ in
            wireSearchCallbacks()
        }
        .onAppear { wireSearchCallbacks() }
    }

    /// Wire `onSearchAtPosition` on all tabs so the FITS viewer can dispatch
    /// coordinate searches through AppState → Search module.
    private func wireSearchCallbacks() {
        for tab in tabHost.tabs where tab.onSearchAtPosition == nil {
            tab.onSearchAtPosition = { [weak appState] ra, dec in
                appState?.dispatch(.searchCoordinates(ra: ra, dec: dec))
            }
        }
    }
}
