// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ResultDetailSheet: View {
    let result: SearchResult
    let columns: SearchResultColumns
    let tapClient: TAPClient
    var researchModel: ResearchModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var dataLink: DataLinkResult?
    @State private var isLoadingImages = false
    @State private var isDownloading = false
    // Local download feedback — scoped to this sheet instance so another view's
    // download status cannot bleed in via the shared ResearchModel properties.
    @State private var downloadMessage: String?
    @State private var downloadIsError = false

    private var publisherID: String { columns.value(in: result, forID: "publisherid") }
    private var collection: String { columns.value(in: result, forID: "collection") }
    private var observationID: String { columns.value(in: result, forID: "obsid") }

    var body: some View {
        VStack(spacing: 0) {
            // Header with actions
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Preview images
                    imageSection

                    // Action buttons
                    actionButtons

                    Divider()

                    // All observation fields
                    fieldsSection
                }
                .padding()
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 500)
        #endif
        .task { await loadDataLinks() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Observation Detail")
                    .font(.headline)
                if !collection.isEmpty || !observationID.isEmpty {
                    Text([collection, observationID].filter { !$0.isEmpty }.joined(separator: " \u{2014} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding()
    }

    // MARK: - Images

    @ViewBuilder
    private var imageSection: some View {
        if isLoadingImages {
            HStack {
                Spacer()
                ProgressView("Loading preview...")
                    .font(.caption)
                Spacer()
            }
            .frame(height: 200)
        } else if let dataLink, !dataLink.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview")
                    .font(.subheadline.bold())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Show previews first, then thumbnails
                        ForEach(Array(allImageURLs.enumerated()), id: \.offset) { _, url in
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 300)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                case .failure:
                                    imagePlaceholder(icon: "exclamationmark.triangle", text: "Failed to load")
                                case .empty:
                                    ProgressView()
                                        .frame(width: 200, height: 200)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                }
            }
        }
        // No images and not loading → show nothing (no placeholder clutter)
    }

    private var allImageURLs: [URL] {
        guard let dataLink else { return [] }
        // Previews first (higher res), then thumbnails as fallback
        var urls = dataLink.previews
        for thumb in dataLink.thumbnails where !urls.contains(thumb) {
            urls.append(thumb)
        }
        return urls
    }

    private func imagePlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 200)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if !publisherID.isEmpty {
                    if let research = researchModel {
                        let alreadyDownloaded = research.isDownloaded(publisherID: publisherID)
                        Button {
                            isDownloading = true
                            downloadMessage = nil
                            Task {
                                await research.downloadObservation(
                                    from: result,
                                    columns: columns,
                                    dataLink: dataLink
                                )
                                isDownloading = false
                                // Pick up status at completion only — scoped to this sheet
                                if let success = research.lastSuccess {
                                    downloadMessage = success
                                    downloadIsError = false
                                } else if let error = research.lastError {
                                    downloadMessage = error
                                    downloadIsError = true
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isDownloading {
                                    ProgressView().scaleEffect(0.6)
                                }
                                Label(
                                    isDownloading ? "Downloading..." : (alreadyDownloaded ? "Re-download" : "Download"),
                                    systemImage: "arrow.down.circle"
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isDownloading)
                    } else if let url = TAPClient.downloadURL(publisherID: publisherID) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Download File", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let url = TAPClient.detailURL(publisherID: publisherID) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("View on CADC", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Spacer()
            }

            // Download feedback — local state, does not bleed across sheets.
            if let downloadMessage {
                Label(
                    downloadMessage,
                    systemImage: downloadIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(downloadIsError ? .red : .green)
            }
        }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Metadata")
                .font(.subheadline.bold())
                .padding(.bottom, 4)

            ForEach(columns.list) { col in
                let raw = columns.value(in: result, forID: col.id)
                if !raw.isEmpty && col.id != "download" && col.id != "preview" {
                    HStack(alignment: .top) {
                        Text(col.label)
                            .font(.caption.bold())
                            .frame(width: 150, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(CellFormatters.format(key: col.id, raw: raw))
                            .font(.caption)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadDataLinks() async {
        guard !publisherID.isEmpty else { return }

        isLoadingImages = true
        do {
            dataLink = try await tapClient.fetchDataLinks(publisherID: publisherID)
        } catch {
            dataLink = DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        }
        isLoadingImages = false
    }
}
