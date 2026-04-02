// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ResearchRootView: View {
    var researchModel: ResearchModel

    var body: some View {
        HSplitView {
            // Left: File browser
            DownloadedFilesView(model: researchModel)
                .frame(minWidth: 250, idealWidth: 300)

            // Right: Detail
            if let observation = researchModel.selectedObservation {
                ObservationDetailView(observation: observation, model: researchModel)
            } else {
                emptyState
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
