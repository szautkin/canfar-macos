// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Shows a small camera icon per row. On hover, fetches and shows thumbnail popover.
struct PreviewThumbnailCell: View {
    let result: SearchResult
    let tapClient: TAPClient
    let onTap: () -> Void

    @State private var isHovering = false
    @State private var thumbnailURL: URL?
    @State private var didFetch = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: thumbnailURL != nil ? "photo.fill" : "photo")
                .font(.caption2)
                .foregroundColor(thumbnailURL != nil ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isHovering) {
            if let url = thumbnailURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 256, maxHeight: 256)
                    case .failure:
                        Text("Failed to load")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 128, height: 64)
                    case .empty:
                        ProgressView()
                            .frame(width: 128, height: 128)
                    @unknown default:
                        EmptyView()
                    }
                }
                .padding(4)
            } else {
                ProgressView("Loading...")
                    .font(.caption)
                    .frame(width: 128, height: 64)
                    .padding(4)
            }
        }
        .onHover { hovering in
            if hovering && !didFetch {
                didFetch = true
                Task { await fetchThumbnail() }
            }
            if hovering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if thumbnailURL != nil || didFetch {
                        isHovering = true
                    }
                }
            } else {
                isHovering = false
            }
        }
    }

    private func fetchThumbnail() async {
        let pid = result.publisherID
        guard !pid.isEmpty else { return }
        do {
            let dataLink = try await tapClient.fetchDataLinks(publisherID: pid)
            thumbnailURL = dataLink.firstThumbnail ?? dataLink.firstPreview
        } catch {
            // Silently fail — just no thumbnail
        }
    }
}
