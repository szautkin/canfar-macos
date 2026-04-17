// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ObservationDetailView: View {
    let observation: DownloadedObservation
    var model: ResearchModel
    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Preview image
                if let previewStr = observation.previewURL ?? observation.thumbnailURL,
                   let previewURL = URL(string: previewStr) {
                    AsyncImage(url: previewURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(minHeight: 120, maxHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure:
                            imagePlaceholder
                        case .empty:
                            ProgressView()
                                .frame(height: 200)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text(observation.targetName.isEmpty ? observation.observationID : observation.targetName)
                        .font(.title2.bold())
                    Text("\(observation.collection) \u{2014} \(observation.observationID)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Actions
                HStack(spacing: 12) {
                    #if os(macOS)
                    Button {
                        model.openFile(observation)
                    } label: {
                        let ext = observation.localURL.pathExtension.lowercased()
                        if FileHelper.isFITS(ext) {
                            Label("Open in FITS Viewer", systemImage: "star.circle")
                        } else if FileHelper.isNotebook(ext) {
                            Label("Open in Notebook", systemImage: "note.text")
                        } else {
                            Label("Open File", systemImage: "doc")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!observation.fileExists)
                    .keyboardShortcut("o")

                    Button {
                        model.revealInFinder(observation)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    #endif

                    if let url = TAPClient.detailURL(publisherID: observation.publisherID) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("View on CADC", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.delete)
                    .confirmationDialog(
                        "Delete \"\(observation.targetName.isEmpty ? observation.observationID : observation.targetName)\"?",
                        isPresented: $showDeleteConfirm
                    ) {
                        Button("Delete", role: .destructive) {
                            model.deleteObservation(observation)
                        }
                    } message: {
                        Text("This will remove the file from disk. This cannot be undone.")
                    }
                }

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 6) {
                    Text("Metadata")
                        .font(.subheadline.bold())

                    metadataRow("Collection", observation.collection)
                    metadataRow("Observation ID", observation.observationID)
                    metadataRow("Target", observation.targetName)
                    metadataRow("Instrument", observation.instrument)
                    metadataRow("Filter", observation.filter)
                    metadataRow("RA", observation.ra)
                    metadataRow("Dec", observation.dec)
                    metadataRow("Start Date", CellFormatters.formatMJDDate(observation.startDate))
                    metadataRow("Cal. Level", CellFormatters.formatCalibrationLevel(observation.calLevel))

                    Divider()

                    Text("File Info")
                        .font(.subheadline.bold())

                    metadataRow("Path", observation.localURL.path)
                    if let size = observation.fileSize {
                        metadataRow("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    metadataRow("Downloaded", formatDate(observation.downloadedAt))
                    metadataRow("Exists", observation.fileExists ? "Yes" : "Missing")
                }

                Divider()

                ObservationNotesView(
                    publisherID: observation.publisherID,
                    store: model.noteStore
                )
            }
            .padding()
        }
    }

    private var imagePlaceholder: some View {
        VStack {
            Image(systemName: "photo")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No preview available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.bold())
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }
}
