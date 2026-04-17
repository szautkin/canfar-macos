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
    let observationStore: ObservationStore
    let downloadService: DownloadService
    let noteStore: ObservationNoteStore
    let exportService = ExportService()

    var activeDownloads: [UUID: DownloadProgress] = [:]
    var selectedObservation: DownloadedObservation?
    var filterText = ""
    var storageUsed: Int64 = 0
    var lastError: String?
    var lastSuccess: String?

    /// Pending auto-dismiss task for toast-style status strings. A single handle
    /// ensures a new success/error replaces any in-flight dismissal, preventing an
    /// older task from clearing a newer message mid-stream.
    private var statusDismissTask: Task<Void, Never>?

    /// Called when the user opens a file; routes FITS/notebook files to in-app viewers.
    var onOpenFile: ((URL) -> Void)?

    init(observationStore: ObservationStore = ObservationStore(),
         downloadService: DownloadService = DownloadService(),
         noteStore: ObservationNoteStore = ObservationNoteStore()) {
        self.observationStore = observationStore
        self.downloadService = downloadService
        self.noteStore = noteStore
    }

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
            scheduleStatusDismiss(after: 2) { [weak self] in
                self?.activeDownloads.removeValue(forKey: downloadID)
                self?.lastSuccess = nil
            }

        } catch {
            activeDownloads[downloadID]?.state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            // Auto-remove failed entry after a short delay
            scheduleStatusDismiss(after: 6) { [weak self] in
                self?.activeDownloads.removeValue(forKey: downloadID)
                self?.lastError = nil
            }
        }
    }

    /// Schedule a delayed clean-up, replacing any pending dismiss so an old handle
    /// cannot wipe state that belongs to a newer download.
    private func scheduleStatusDismiss(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        statusDismissTask?.cancel()
        statusDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            body()
            self?.statusDismissTask = nil
        }
    }

    func isDownloaded(publisherID: String) -> Bool {
        observationStore.contains(publisherID: publisherID)
    }

    // MARK: - File Management

    func deleteObservation(_ observation: DownloadedObservation) {
        let url = URL(fileURLWithPath: observation.localPath)
        Task {
            // Delete file first; ignore errors — file may already be gone
            try? await downloadService.deleteFile(at: url)
            // Remove metadata only after file deletion is attempted
            observationStore.remove(observation)
            if selectedObservation?.id == observation.id {
                selectedObservation = nil
            }
        }
    }

    // MARK: - Export

    /// Run an export bundle containing this module's data. Presents a folder picker,
    /// writes a Claude-friendly bundle, and reveals it in Finder on success.
    #if os(macOS)
    func presentExportFlow() async {
        guard let destination = await pickExportDestination() else { return }
        let exporter = ResearchExporter(
            observationStore: observationStore,
            noteStore: noteStore
        )
        if let bundleURL = await exportService.exportAll(to: destination, modules: [exporter]) {
            let summary = exportSummary()
            lastSuccess = "Exported \(summary)"
            NSWorkspace.shared.selectFile(
                bundleURL.path,
                inFileViewerRootedAtPath: destination.path
            )
            NotificationService.sendExportCompleted(
                bundleName: bundleURL.lastPathComponent,
                moduleSummary: summary
            )
            scheduleStatusDismiss(after: 4) { [weak self] in self?.lastSuccess = nil }
        } else if let err = exportService.lastError {
            lastError = "Export failed: \(err)"
            scheduleStatusDismiss(after: 6) { [weak self] in self?.lastError = nil }
        }
    }

    private func exportSummary() -> String {
        ResearchExporter.itemCountLabel(
            observations: observationStore.observations.count,
            notes: noteStore.notes.count
        )
    }

    @MainActor
    private func pickExportDestination() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Export Destination"
        panel.message = "A timestamped folder will be created inside the selected directory."
        panel.prompt = "Export Here"

        // Default to iCloud Drive/Verbinal if it exists, else ~/Documents
        let fm = FileManager.default
        let iCloud = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Verbinal")
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        if let iCloud, fm.fileExists(atPath: iCloud.path) {
            panel.directoryURL = iCloud
        } else {
            panel.directoryURL = docs
        }

        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif

    #if os(macOS)
    func revealInFinder(_ observation: DownloadedObservation) {
        let url = URL(fileURLWithPath: observation.localPath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func openFile(_ observation: DownloadedObservation) {
        let url = URL(fileURLWithPath: observation.localPath)
        guard observation.fileExists else { return }
        let ext = url.pathExtension.lowercased()
        if FileHelper.isFITS(ext) || FileHelper.isNotebook(ext) {
            onOpenFile?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
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
            try FileHelper.moveReplacing(from: tempURL, to: saveURL)
            return saveURL
        } catch {
            lastError = "Failed to save: \(error.localizedDescription)"
            return nil
        }
    }
    #endif
}
