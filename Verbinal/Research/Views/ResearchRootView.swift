// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ResearchRootView: View {
    var researchModel: ResearchModel
    var searchModel: SearchFormModel?

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = researchModel.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { researchModel.lastError = nil }
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.08))
                Divider()
            }

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Left: File browser — 1/4 width, fixed
                    DownloadedFilesView(model: researchModel, searchModel: searchModel)
                        .frame(width: geometry.size.width * 0.25)

                    Divider()

                    // Right: Detail — 3/4 width
                    Group {
                        if let observation = researchModel.selectedObservation {
                            ObservationDetailView(observation: observation, model: researchModel)
                                // Give the detail a per-observation identity so SwiftUI
                                // rebuilds it (and its NoteEditingModel) on selection change
                                // instead of reusing the instance in place. Defense-in-depth
                                // alongside NoteEditingModel's key-safe load/flush.
                                .id(observation.id)
                        } else {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottom) {
                if researchModel.hasActiveDownloads {
                    DownloadProgressView(model: researchModel)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select an observation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Download observations from Search to view them here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
