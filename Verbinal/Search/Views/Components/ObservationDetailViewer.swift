// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Rich CAOM2-aware detail viewer — the canonical observation-detail surface.
/// Renders three layers:
///
/// 1. **Row data** (always visible) — Target, Collection, ObsID hero,
///    plus the Raw tab dumping every column the row carries.
/// 2. **CAOM2 detail** (async) — Fetched from `caom2ops/meta` for public
///    collections; populates Overview / Coverage / Files / Provenance once
///    parsed. Loading and auth-gate states are first-class.
/// 3. **Actions** — Open on CADC web UI, Download via the existing
///    DataLink path. These work regardless of CAOM2 fetch status.
struct ObservationDetailViewer: View {
    @State var model: ObservationDetailModel
    let tapClient: TAPClient
    var researchModel: ResearchModel?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var dataLink: DataLinkResult?
    @State private var isLoadingDataLink = false
    @State private var selectedTab: Tab = .overview
    @State private var isDownloading = false
    @State private var downloadMessage: String?
    @State private var downloadIsError = false

    enum Tab: String, CaseIterable, Identifiable {
        case overview, coverage, files, provenance, raw
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .overview:   return "Overview"
            case .coverage:   return "Coverage"
            case .files:      return "Files"
            case .provenance: return "Provenance"
            case .raw:        return "Raw"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Divider()
            tabBar
            Divider()
            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 620)
        #endif
        .task {
            await model.loadCAOM2()
            await loadDataLink()
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            heroPreview

            VStack(alignment: .leading, spacing: 6) {
                Text(heroTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text(heroSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                heroActions
                    .padding(.top, 6)

                if let downloadMessage {
                    Label(
                        downloadMessage,
                        systemImage: downloadIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(downloadIsError ? .red : .green)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(16)
    }

    private var heroTitle: String {
        let name = model.targetName
        return name.isEmpty ? String(localized: "Observation Detail") : name
    }

    private var heroSubtitle: String {
        [model.collection, model.observationID].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var heroPreview: some View {
        Group {
            if let url = dataLink?.firstThumbnail ?? dataLink?.firstPreview {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    case .empty: ProgressView().controlSize(.small)
                    @unknown default: EmptyView()
                    }
                }
            } else if isLoadingDataLink {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 96)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var heroActions: some View {
        HStack(spacing: 8) {
            if !model.publisherID.isEmpty {
                if let research = researchModel {
                    let alreadyDownloaded = research.isDownloaded(publisherID: model.publisherID)
                    Button {
                        startDownload(research: research)
                    } label: {
                        HStack(spacing: 4) {
                            if isDownloading { ProgressView().scaleEffect(0.6) }
                            Label(
                                isDownloading ? String(localized: "Downloading…")
                                              : (alreadyDownloaded ? String(localized: "Re-download")
                                                                   : String(localized: "Download")),
                                systemImage: "arrow.down.circle"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDownloading)
                } else if let url = TAPClient.downloadURL(publisherID: model.publisherID) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Download File", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let url = TAPClient.detailURL(publisherID: model.publisherID) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("View on CADC", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .labelsHidden()
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:   ObservationOverviewSection(model: model)
        case .coverage:   ObservationCoverageSection(model: model)
        case .files:      ObservationFilesSection(model: model)
        case .provenance: ObservationProvenanceSection(model: model)
        case .raw:        ObservationRawSection(model: model)
        }
    }

    // MARK: - Side effects

    private func loadDataLink() async {
        guard !model.publisherID.isEmpty else { return }
        isLoadingDataLink = true
        defer { isLoadingDataLink = false }
        dataLink = (try? await tapClient.fetchDataLinks(publisherID: model.publisherID))
            ?? DataLinkResult(thumbnails: [], previews: [], directFiles: [])
    }

    private func startDownload(research: ResearchModel) {
        isDownloading = true
        downloadMessage = nil
        Task {
            await research.downloadObservation(
                from: model.result,
                columns: model.columns,
                dataLink: dataLink
            )
            isDownloading = false
            if let success = research.lastSuccess {
                downloadMessage = success
                downloadIsError = false
            } else if let error = research.lastError {
                downloadMessage = error
                downloadIsError = true
            }
        }
    }
}
