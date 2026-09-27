// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Cutouts for agents: the options, and a cutout downloaded into Research.
extension AppState {

    /// The ways an observation's files can be cut, and — when there are
    /// none — why.
    func cutoutSources(publisherID: String) async -> (sources: [any CutoutSource], problems: [String]) {
        let options = await cutoutService.options(publisherID: publisherID)
        return (options.sources, options.problems)
    }

    func makeGetCutoutOptionsTool() -> GetCutoutOptionsTool {
        GetCutoutOptionsTool(options: { [weak self] publisherID in
            guard let self else { return CutoutOptionsOutput.from(publisherId: publisherID, sources: [], hints: nil, problems: []) }
            let (sources, problems) = await self.cutoutSources(publisherID: publisherID)
            let hints = await MainActor.run { self.searchModel.cutoutHints }
            return CutoutOptionsOutput.from(publisherId: publisherID, sources: sources, hints: hints, problems: problems)
        })
    }

    func makeDownloadCutoutTool() -> DownloadCutoutTool {
        DownloadCutoutTool(sources: { [weak self] publisherID in
            await self?.cutoutSources(publisherID: publisherID).sources ?? []
        })
    }

    func makeShowCutoutEditorTool() -> ShowCutoutEditorTool {
        ShowCutoutEditorTool(show: { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            let pid = args.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
            // CADC first: the region is set against the file it names, and a file is chosen, not guessed.
            let (sources, problems) = await self.cutoutSources(publisherID: pid)
            guard !sources.isEmpty else {
                return CutoutEditorShown(shown: false, artifactId: nil, summary: nil, errors: [], warnings: [],
                                         estimatedBytes: nil, message: ([CutoutOptionsOutput.noneCanBeCut] + problems).joined(separator: " — "))
            }
            let initial: CutoutSpec? = args.asksAnything || args.artifactId != nil
                ? try { let source = try args.pickSource(sources)
                        return args.asksAnything ? try args.spec(for: source) : source.suggest(nil) }()
                : nil
            return await MainActor.run {
                let editor = CutoutEditorModel(publisherID: pid, details: self.observationDetails(publisherID: pid),
                                               service: self.cutoutService, hints: self.searchModel.cutoutHints, initial: initial)
                editor.present(sources: sources, problems: problems)
                self.cutoutEditor = editor
                self.agentsService.activityStore.append(.live(
                    kind: "show_cutout_editor", summary: "Opened the cutout editor on \(pid)",
                    origin: .external(clientID: "show_cutout_editor")))
                let spec = try? editor.spec.get()
                return CutoutEditorShown(shown: true, artifactId: editor.source?.file.artifactID, summary: spec?.summary,
                                         errors: editor.check?.errors.map(\.message) ?? [],
                                         warnings: editor.check?.warnings.map(\.message) ?? [],
                                         estimatedBytes: editor.estimatedBytes, message: nil)
            }
        })
    }

    func makeCutoutAppliers(activity: AgentActivityStore) -> [any ProposalApplier] {
        [
            DownloadCutoutApplier(download: { [weak self] payload, attribution in
                guard let self else { throw ProposalApplyError.backendError("app state gone") }
                let temp = try await SodaCutoutMaker(service: self.cutoutService).make(publisherID: payload.publisherId, spec: payload.spec)
                let downloads = await MainActor.run { self.researchModel.downloadService }
                let placed = try await placeInDownloads(tempURL: temp, suggestedFilename: payload.spec.fileName, downloadService: downloads)
                return await MainActor.run {
                    var record = self.observationDetails(publisherID: payload.publisherId)
                    record.id = UUID()
                    record.cutout = payload.spec
                    record.localPath = placed.localPath
                    record.fileSize = placed.size
                    record.bookmarkData = placed.bookmark
                    record.downloadedAt = Date()
                    record.agentAttribution = attribution
                    return self.researchModel.observationStore.save(record).id
                }
            }, activity: activity),
        ]
    }

    /// An observation's details for a new Research record, without its
    /// file: Research's own record of it, else the search row, else what its
    /// publisher ID says (`fallback` when given).
    @MainActor
    func observationDetails(publisherID: String, fallback: DownloadedObservation? = nil) -> DownloadedObservation {
        if let kept = researchModel.observationStore.whole(publisherID: publisherID) { return kept.withoutFile() }
        let results = searchModel.resultsModel
        if let row = results.result(publisherID: publisherID) {
            return DownloadedObservation.from(result: row, columns: results.columns, localPath: "")
        }
        return fallback ?? SaveObservationToResearchTool.record(from: .init(publisherId: publisherID))
    }
}
