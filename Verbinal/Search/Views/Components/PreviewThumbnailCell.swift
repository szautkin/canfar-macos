// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import os.log

/// Shows a small camera icon per row. On hover, fetches and shows thumbnail popover.
///
/// Depends only on `publisherID` — the cell is column-agnostic. Callers that hold
/// a `SearchResult` + `SearchResultColumns` resolve the id at the call site.
struct PreviewThumbnailCell: View {
    let publisherID: String
    let tapClient: TAPClient
    let onTap: () -> Void

    @State private var isHovering = false
    @State private var thumbnailURL: URL?
    @State private var didFetch = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            Image(systemName: thumbnailURL != nil ? "photo.fill" : "photo")
                .font(.caption2)
                .foregroundColor(thumbnailURL != nil ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Preview"))
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
            // Cancel any pending delayed-open so a quick hover-out doesn't flash
            // the popover after the cursor has already left.
            hoverTask?.cancel()

            guard hovering else {
                isHovering = false
                return
            }

            if !didFetch {
                didFetch = true
                Task { await fetchThumbnail() }
            }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if thumbnailURL != nil || didFetch {
                    isHovering = true
                }
            }
        }
    }

    private func fetchThumbnail() async {
        guard !publisherID.isEmpty else { return }
        thumbnailURL = await Self.resolveThumbnailURL(publisherID: publisherID) {
            try await tapClient.fetchDataLinks(publisherID: publisherID)
        }
    }

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PreviewThumbnail")

    /// Resolves a thumbnail/preview URL from a DataLink fetch, returning `nil`
    /// on any failure. Failures are intentionally swallowed for graceful
    /// degradation (no error UI on a hover popover) but emit a debug log so a
    /// genuine fetch/logic problem is observable rather than invisible.
    ///
    /// Extracted to a static helper so the swallow-and-return-nil contract is
    /// unit-testable with an injected throwing `fetch` double, without standing
    /// up a SwiftUI view or hitting the network.
    static func resolveThumbnailURL(
        publisherID: String,
        fetch: () async throws -> DataLinkResult
    ) async -> URL? {
        do {
            let dataLink = try await fetch()
            return dataLink.firstThumbnail ?? dataLink.firstPreview
        } catch {
            // Graceful degradation — no thumbnail, no UI error. Log so the
            // failure is observable when debugging preview behavior.
            logger.debug("DataLink thumbnail fetch failed for \(publisherID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
