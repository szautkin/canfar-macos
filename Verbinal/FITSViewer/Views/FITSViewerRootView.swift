// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSViewerRootView: View {
    @State private var viewerModel = FITSViewerModel()

    var body: some View {
        HSplitView {
            // Left: HDU list + controls
            sidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)

            // Right: image viewer + coordinate bar
            VStack(spacing: 0) {
                if viewerModel.isLoading {
                    Spacer()
                    ProgressView("Loading FITS...")
                    Spacer()
                } else if let error = viewerModel.loadError {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                    }
                    Spacer()
                } else if viewerModel.renderedImage != nil {
                    FITSImageView(model: viewerModel)
                    Divider()
                    FITSCoordinateBar(model: viewerModel)
                } else {
                    emptyState
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Open file button
            HStack {
                #if os(macOS)
                Button {
                    Task { await viewerModel.openWithPicker() }
                } label: {
                    Label("Open FITS", systemImage: "doc.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                #endif
                Spacer()
            }
            .padding(8)

            Divider()

            // HDU list
            if !viewerModel.imageHDUs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HDUs")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                    ForEach(viewerModel.imageHDUs) { hdu in
                        Button {
                            Task { await viewerModel.selectHDU(hdu.id) }
                        } label: {
                            HStack {
                                Image(systemName: viewerModel.selectedHDUIndex == hdu.id ? "circle.fill" : "circle")
                                    .font(.caption2)
                                Text(hdu.label)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }

            // Render controls
            FITSRenderControlsView(model: viewerModel)

            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No FITS file open")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open a FITS file to view it here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
