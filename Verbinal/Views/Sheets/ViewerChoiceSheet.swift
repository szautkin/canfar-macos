// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Choose 2D FITS vs 3D Cube when opening a file with NAXIS≥3
/// (Windows 1.3.1 viewer-choice parity).
struct ViewerChoiceSheet: View {
    @Environment(AppState.self) private var appState
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open as…")
                .font(.title2.bold())
            Text(url.lastPathComponent)
                .font(.callout.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            Text("This file has a third axis. Open it in the 2D FITS Viewer or the 3D Cube Viewer.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("FITS Viewer (2D)") {
                    appState.openPendingViewerChoiceAsFITS()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Cube Viewer (3D)") {
                    appState.openPendingViewerChoiceAsCube()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .onEscape { appState.pendingViewerChoiceURL = nil }
    }
}
