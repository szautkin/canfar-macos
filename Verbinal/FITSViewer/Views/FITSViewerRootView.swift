// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSViewerRootView: View {
    @State private var tabHost = FITSTabHostModel()

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
    }
}
