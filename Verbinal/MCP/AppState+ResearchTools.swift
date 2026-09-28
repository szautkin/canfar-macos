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

    // MARK: - Records without their file

    func makeShowResearchObservationTool() -> LiveActionTool<ResearchActions.ShowArgs> {
        ResearchActions.show { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard let record = self.researchModel.observationStore.record(identifiedBy: args.id) else {
                    return "no observation \"\(args.id)\" in Research — list_downloaded_observations gives the ids"
                }
                self.researchModel.selectedObservation = record
                self.navigateTo(.research)
                self.agentsService.activityStore.append(.live(
                    kind: "show_research_observation",
                    summary: "Showed \(record.targetName.isEmpty ? record.observationID : record.targetName) in Research",
                    origin: .external(clientID: "show_research_observation")))
                return nil
            }
        }
    }

    /// Keeping an observation without its file, and removing a file while
    /// keeping the observation.
    func makeResearchRecordAppliers(activity: AgentActivityStore) -> [any ProposalApplier] {
        [
            SaveObservationToResearchApplier(save: { [weak self] payload, attribution in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                return await MainActor.run {
                    var record = self.observationDetails(publisherID: payload.publisherId,
                                                         fallback: SaveObservationToResearchTool.record(from: payload))
                    record.agentAttribution = attribution
                    let kept = self.researchModel.observationStore.keep(record)
                    return (kept.record.id, kept.added)
                }
            }, activity: activity),
            RemoveDownloadedFileApplier(remove: { [weak self] id in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let record = await MainActor.run { self.researchModel.observationStore.record(identifiedBy: id) }
                guard let record else {
                    throw ProposalApplyError.backendError("no observation \"\(id)\" in Research")
                }
                guard record.isDownloaded else {
                    throw ProposalApplyError.backendError("\(id) has no file on this computer — nothing to remove")
                }
                try await self.researchModel.removeFile(record)
            }, activity: activity),
        ]
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
            fileProblem: obs.fileProblem?.message,
            fileSize: obs.fileSize,
            downloadedAt: obs.downloadedAt,
            cutout: obs.cutout
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
