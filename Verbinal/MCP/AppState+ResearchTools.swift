// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Research: downloaded observations, their notes, and the bundle export.
extension AppState {
    func makeListDownloadedObservationsTool(store: ObservationStore) -> ListDownloadedObservationsTool {
        ListDownloadedObservationsTool(snapshot: { @MainActor in
            store.observations.map { Self.flatten($0) }
        })
    }

    func makeGetDownloadedObservationTool(store: ObservationStore) -> GetDownloadedObservationTool {
        GetDownloadedObservationTool(lookup: { @MainActor raw in
            store.observation(matching: raw).map { Self.flatten($0) }
        })
    }

    func makeGetObservationNotesTool(store: ObservationNoteStore) -> GetObservationNotesTool {
        GetObservationNotesTool(lookup: { @MainActor pid in
            guard let note = store.note(for: pid) else { return nil }
            return ObservationNoteOut(
                publisherID: note.publisherID,
                text: note.text,
                rating: note.rating,
                tags: note.tags,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt,
                isEmpty: note.isEmpty
            )
        })
    }

    private nonisolated static func flatten(_ obs: DownloadedObservation) -> DownloadedObservationOut {
        DownloadedObservationOut(
            id: obs.id.uuidString,
            publisherID: obs.publisherID,
            collection: obs.collection,
            observationID: obs.observationID,
            targetName: obs.targetName,
            instrument: obs.instrument,
            filter: obs.filter,
            calLevel: obs.calLevel,
            localPath: obs.localPath,
            fileExists: obs.fileExists,
            fileSize: obs.fileSize,
            downloadedAt: obs.downloadedAt
        )
    }

    /// Headless twin of the Export dialog's happy path: Research module →
    /// timestamped bundle in ~/Downloads, optional zip-and-upload to
    /// VOSpace `Verbinal-Exports/`.
    func runResearchBundleExport(
        includeFileCopies: Bool,
        uploadToVOSpace: Bool,
        vospace: VOSpaceBrowserService,
        observationStore: ObservationStore,
        noteStore: ObservationNoteStore
    ) async throws {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let exporter = ResearchExporter(observationStore: observationStore, noteStore: noteStore)
        let service = ExportService()
        let options = ExportOptions(includeFileCopies: includeFileCopies)
        guard let bundleURL = await service.exportAll(to: downloads, modules: [exporter], options: options) else {
            throw ProposalApplyError.backendError(service.lastError ?? "export failed")
        }
        if uploadToVOSpace {
            guard !username.isEmpty else {
                throw ProposalApplyError.backendError("Sign in to CADC before uploading to VOSpace")
            }
            _ = try await service.uploadBundleToVOSpace(
                bundleURL: bundleURL, vospace: vospace, username: username)
        }
    }
}
