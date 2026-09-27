// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

struct ObservationDetailView: View {
    let observation: DownloadedObservation
    var model: ResearchModel
    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirm = false
    @State private var showRemoveFileConfirm = false
    /// The cutout editor, open on this observation.
    @State private var cutoutEditor: CutoutEditorModel?
    /// Why removing the file failed.
    @State private var fileProblem: String?
    /// True when the downloaded FITS file is a spectral cube, so the Open
    /// button can name the Cube Viewer the router will actually pick.
    @State private var isCube = false

    private var title: String {
        observation.targetName.isEmpty ? observation.observationID : observation.targetName
    }

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
                    Text(title)
                        .font(.title2.bold())
                    Text("\(observation.collection) \u{2014} \(observation.observationID)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let cutout = observation.cutout {
                    cutoutBanner(cutout)
                }

                // Actions
                HStack(spacing: 12) {
                    #if os(macOS)
                    if let fileURL = observation.localURL {
                        Button {
                            model.openFile(observation)
                        } label: {
                            if FileHelper.isFITS(fileURL.pathExtension.lowercased()) {
                                if isCube {
                                    Label("Open in Cube Viewer", systemImage: "cube")
                                } else {
                                    Label("Open in FITS Viewer", systemImage: "star.circle")
                                }
                            } else {
                                Label("Open File", systemImage: "doc")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!observation.fileExists)
                        .keyboardShortcut("o")
                        .task(id: fileURL) {
                            // Name the viewer the router will pick (same header sniff).
                            guard observation.fileExists, FileHelper.isFITS(fileURL.pathExtension.lowercased()) else {
                                isCube = false
                                return
                            }
                            isCube = await AppState.fitsIsCube(fileURL)
                        }

                        Button {
                            model.revealInFinder(observation)
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    } else {
                        Button {
                            Task { await model.download(observation) }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Fetch this observation's file from CADC")
                    }
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

                    if !observation.isCutout {
                        Button {
                            cutoutEditor = CutoutEditorModel(publisherID: observation.publisherID, details: observation,
                                                             service: model.cutoutService)
                        } label: {
                            Label("Cut Out…", systemImage: "scissors")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Download only part of a file, cut on CADC's side")
                    }

                    Button {
                        PlatformClipboard.copy(observation.facts.detailsText)
                    } label: {
                        Label("Copy Details", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy this observation's details — ID, position, instrument, date — as text")

                    Spacer()

                    if observation.isDownloaded {
                        Button {
                            showRemoveFileConfirm = true
                        } label: {
                            Label("Remove File…", systemImage: "doc.badge.minus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Delete the file from this computer and keep the observation and its notes")
                        .confirmationDialog("Remove the file of \"\(title)\"?", isPresented: $showRemoveFileConfirm) {
                            Button("Remove File", role: .destructive) {
                                Task {
                                    do { try await model.removeFile(observation) } catch {
                                        fileProblem = String(localized: "Could not remove the file: \(error.localizedDescription)")
                                    }
                                }
                            }
                        } message: {
                            Text("The file is deleted from this computer. The observation, its details and notes stay in Research, and Download fetches the file again.")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.delete)
                    .confirmationDialog(
                        "Delete \"\(title)\"?",
                        isPresented: $showDeleteConfirm
                    ) {
                        Button("Delete", role: .destructive) {
                            model.deleteObservation(observation)
                        }
                    } message: {
                        if observation.isDownloaded {
                            Text("This will remove the file from disk. This cannot be undone.")
                        } else {
                            Text("This removes the observation and its place in Research. Its notes are kept.")
                        }
                    }
                }

                if let fileProblem {
                    Text(fileProblem).font(.caption).foregroundStyle(.red)
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

                    if let fileURL = observation.localURL {
                        metadataRow("Path", fileURL.path)
                        if let size = observation.fileSize {
                            metadataRow("Size", SharedFormatters.bytes(size))
                        }
                        metadataRow("Downloaded", formatDate(observation.downloadedAt))
                        metadataRow("Exists", observation.fileExists ? String(localized: "Yes") : String(localized: "Missing"))
                    } else {
                        metadataRow("File", String(localized: "Not downloaded"))
                        metadataRow("Saved", formatDate(observation.downloadedAt))
                    }
                }

                Divider()

                ObservationNotesView(
                    publisherID: observation.publisherID,
                    store: model.noteStore
                )
            }
            .padding()
        }
        .sheet(item: $cutoutEditor) { editor in
            CutoutEditorView(model: editor) { spec in
                Task { await model.downloadCutout(of: editor.details, spec) }
            }
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

    /// A cutout says what it is part of, and leads back to the whole.
    private func cutoutBanner(_ cutout: CutoutSpec) -> some View {
        let original = model.observationStore.whole(publisherID: observation.publisherID)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "scissors").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cutout of \(CutoutSpec.artifactFileName(cutout.artifactID))").font(.callout.bold())
                Text(cutout.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Original Observation") {
                model.selectedObservation = original
            }
            .controlSize(.small)
            .disabled(original == nil)
            .help(original == nil ? "The complete observation is not in Research" : "Show the complete observation this was cut from")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func metadataRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.bold())
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? String(localized: "-") : value)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
