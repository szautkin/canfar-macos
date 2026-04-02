// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DownloadedFilesView: View {
    var model: ResearchModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                Text("\(model.observationStore.observations.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Filter
            TextField("Filter...", text: Bindable(model).filterText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // File list grouped by collection
            if model.filteredObservations.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(model.observationStore.observations.isEmpty ? "No downloaded observations" : "No matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedObservation?.id },
                    set: { newID in
                        model.selectedObservation = model.observationStore.observations.first { $0.id == newID }
                    }
                )) {
                    let grouped = Dictionary(grouping: model.filteredObservations, by: \.collection)
                    ForEach(grouped.keys.sorted(), id: \.self) { collection in
                        Section(collection) {
                            ForEach(grouped[collection]!) { obs in
                                observationRow(obs)
                                    .tag(obs.id)
                                    .contextMenu {
                                        #if os(macOS)
                                        Button("Open File") { model.openFile(obs) }
                                        Button("Reveal in Finder") { model.revealInFinder(obs) }
                                        Divider()
                                        #endif
                                        Button("Delete", role: .destructive) { model.deleteObservation(obs) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func observationRow(_ obs: DownloadedObservation) -> some View {
        HStack(spacing: 8) {
            // Thumbnail
            if let thumbStr = obs.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                AsyncImage(url: thumbURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "doc")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(obs.targetName.isEmpty ? obs.observationID : obs.targetName)
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(obs.instrument)
                    if !obs.filter.isEmpty {
                        Text("/ \(obs.filter)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if let size = obs.fileSize {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
