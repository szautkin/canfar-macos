// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DownloadProgressView: View {
    var model: ResearchModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                ForEach(model.activeDownloadList) { download in
                    HStack(spacing: 8) {
                        // Status icon
                        switch download.state {
                        case .downloading:
                            ProgressView()
                                .scaleEffect(0.6)
                        case .completed:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        case .cancelled:
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(download.observation.targetName.isEmpty
                                 ? download.observation.observationID
                                 : download.observation.targetName)
                                .font(.caption)
                                .lineLimit(1)

                            if download.state == .downloading {
                                ProgressView(value: download.fractionCompleted)
                                    .progressViewStyle(.linear)

                                Text(download.formattedProgress)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if case .failed(let msg) = download.state {
                                Text(msg)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
