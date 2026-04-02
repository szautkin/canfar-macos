// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Orchestrates the Research module: downloaded observations, active downloads, file management.
@Observable
@MainActor
final class ResearchModel {
    let observationStore = ObservationStore()
    let downloadService = DownloadService()

    var activeDownloads: [UUID: DownloadProgress] = [:]
    var selectedObservation: DownloadedObservation?
    var filterText = ""
    var storageUsed: Int64 = 0
    var lastError: String?
    var lastSuccess: String?

    var filteredObservations: [DownloadedObservation] {
        guard !filterText.isEmpty else { return observationStore.observations }
        let query = filterText.lowercased()
        return observationStore.observations.filter {
            $0.targetName.lowercased().contains(query) ||
            $0.collection.lowercased().contains(query) ||
            $0.instrument.lowercased().contains(query) ||
            $0.observationID.lowercased().contains(query)
        }
    }

    var activeDownloadList: [DownloadProgress] {
        Array(activeDownloads.values).sorted { $0.observation.downloadedAt > $1.observation.downloadedAt }
    }

    var hasActiveDownloads: Bool {
        activeDownloads.values.contains { $0.state == .downloading }
    }

    // MARK: - Download

    /// Download an observation: fetch to temp, let user choose save location, store metadata.
    func downloadObservation(from result: SearchResult, dataLink: DataLinkResult?) async {
        let downloadID = UUID()
        let placeholder = DownloadedObservation.from(result: result, localPath: "", dataLink: dataLink)
        activeDownloads[downloadID] = DownloadProgress(id: downloadID, observation: placeholder)
        lastError = nil
        lastSuccess = nil

        do {
            // Step 1: Download to temp
            let (tempURL, suggestedFilename) = try await downloadService.downloadToTemp(
                publisherID: result.publisherID
            )

            activeDownloads[downloadID]?.state = .completed

            // Step 2: Let user choose save location
            #if os(macOS)
            let savedURL = await presentSavePanel(suggestedFilename: suggestedFilename, tempURL: tempURL)
            #else
            let savedURL: URL? = nil
            #endif

            guard let finalURL = savedURL else {
                // User cancelled — clean up temp
                try? await downloadService.deleteFile(at: tempURL)
                activeDownloads.removeValue(forKey: downloadID)
                return
            }

            // Step 3: Get file size and store metadata
            let fileSize = await downloadService.fileSize(at: finalURL)
            var observation = DownloadedObservation.from(
                result: result,
                localPath: finalURL.path,
                dataLink: dataLink
            )
            observation.fileSize = fileSize

            observationStore.save(observation)
            lastSuccess = "Saved: \(suggestedFilename)"

            // Clean up active download indicator
            Task {
                try? await Task.sleep(for: .seconds(2))
                activeDownloads.removeValue(forKey: downloadID)
                lastSuccess = nil
            }

        } catch {
            activeDownloads[downloadID]?.state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func isDownloaded(publisherID: String) -> Bool {
        observationStore.contains(publisherID: publisherID)
    }

    // MARK: - File Management

    func deleteObservation(_ observation: DownloadedObservation) {
        let url = URL(fileURLWithPath: observation.localPath)
        Task { try? await downloadService.deleteFile(at: url) }
        observationStore.remove(observation)
        if selectedObservation?.id == observation.id {
            selectedObservation = nil
        }
    }

    #if os(macOS)
    func revealInFinder(_ observation: DownloadedObservation) {
        let url = URL(fileURLWithPath: observation.localPath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func openFile(_ observation: DownloadedObservation) {
        let url = URL(fileURLWithPath: observation.localPath)
        NSWorkspace.shared.open(url)
    }
    #endif

    // MARK: - Save Panel

    #if os(macOS)
    @MainActor
    private func presentSavePanel(suggestedFilename: String, tempURL: URL) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.title = "Save Observation"
        panel.message = "Choose where to save the downloaded observation file."

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let verbinalDir = docs?.appendingPathComponent("Verbinal")
        if let verbinalDir, FileManager.default.fileExists(atPath: verbinalDir.path) {
            panel.directoryURL = verbinalDir
        } else {
            panel.directoryURL = docs
        }

        let response = panel.runModal()
        guard response == .OK, let saveURL = panel.url else { return nil }
        return moveToFinal(from: tempURL, to: saveURL)
    }

    private func moveToFinal(from tempURL: URL, to saveURL: URL) -> URL? {
        do {
            if FileManager.default.fileExists(atPath: saveURL.path) {
                try FileManager.default.removeItem(at: saveURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: saveURL)
            return saveURL
        } catch {
            lastError = "Failed to save: \(error.localizedDescription)"
            return nil
        }
    }
    #endif
}
