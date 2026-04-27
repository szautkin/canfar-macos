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
    func downloadObservation(
        from result: SearchResult,
        columns: SearchResultColumns,
        dataLink: DataLinkResult?
    ) async {
        let publisherID = columns.value(in: result, forID: "publisherid")
        let downloadID = UUID()
        let placeholder = DownloadedObservation.from(result: result, columns: columns, localPath: "", dataLink: dataLink)
        activeDownloads[downloadID] = DownloadProgress(id: downloadID, observation: placeholder)
        lastError = nil
        lastSuccess = nil

        do {
            // Step 1: Download to temp
            let (tempURL, suggestedFilename) = try await downloadService.downloadToTemp(
                publisherID: publisherID
            )

            activeDownloads[downloadID]?.state = .completed

            // Step 2: Let user choose save location
            #if os(macOS)
            let saveResult = await presentSavePanel(suggestedFilename: suggestedFilename, tempURL: tempURL)
            #else
            let saveResult: SaveResult? = nil
            #endif

            guard let saveResult else {
                // User cancelled — clean up temp
                try? await downloadService.deleteFile(at: tempURL)
                activeDownloads.removeValue(forKey: downloadID)
                return
            }
            let finalURL = saveResult.url

            // Step 3: Get file size and store metadata (with the security-
            // scoped bookmark we captured during the save panel session).
            let fileSize = await downloadService.fileSize(at: finalURL)
            var observation = DownloadedObservation.from(
                result: result,
                columns: columns,
                localPath: finalURL.path,
                bookmarkData: saveResult.bookmarkData,
                dataLink: dataLink
            )
            observation.fileSize = fileSize

            observationStore.save(observation)
            lastSuccess = String(localized: "Saved: \(suggestedFilename)")

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
            lastSuccess = String(localized: "Exported \(summary)")
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
            lastError = String(localized: "Export failed: \(err)")
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
        panel.title = String(localized: "Choose Export Destination")
        panel.message = String(localized: "A timestamped folder will be created inside the selected directory.")
        panel.prompt = String(localized: "Export Here")

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
        let url = resolvedURL(for: observation) ?? URL(fileURLWithPath: observation.localPath)
        // NSWorkspace runs in Finder's process and has its own grant — no
        // start/stopAccessingSecurityScopedResource needed here.
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func openFile(_ observation: DownloadedObservation) {
        // Prefer the security-scoped bookmark — that's the only path that
        // works for files outside ~/Downloads after app restart. Fall back
        // to the path-only URL for legacy rows; if that fails the
        // permission probe, route through the re-grant flow.
        let resolved = resolvedURL(for: observation)
        let candidate = resolved ?? URL(fileURLWithPath: observation.localPath)

        guard FileManager.default.fileExists(atPath: candidate.path) else { return }

        let ext = candidate.pathExtension.lowercased()

        // Path-only URL + sandbox refuses the read → ask the user to
        // re-grant access via NSOpenPanel pre-targeted to the file.
        if resolved == nil && !FileManager.default.isReadableFile(atPath: candidate.path) {
            requestAccessRegrant(for: observation)
            return
        }

        if FileHelper.isFITS(ext) {
            onOpenFile?(candidate)
        } else {
            NSWorkspace.shared.open(candidate)
        }
    }

    /// Resolve `observation.bookmarkData` to a fresh security-scoped URL.
    /// Returns `nil` when:
    ///  • the observation has no bookmark (legacy save), or
    ///  • the bookmark was created on a different volume / removed file, or
    ///  • the system refuses to start the security scope.
    /// Stale bookmarks are silently re-created so the next save persists
    /// the refreshed token.
    private func resolvedURL(for observation: DownloadedObservation) -> URL? {
        guard let data = observation.bookmarkData else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        // Caller is the FITS viewer / NSWorkspace — they finish reading
        // synchronously (FITSViewerModel.open uses Data(contentsOf:) once)
        // and won't call back, so we balance the access here. The viewer
        // wraps subsequent reads in its own scope-pair (see
        // FITSViewerModel.open / .selectHDU).
        url.stopAccessingSecurityScopedResource()
        if stale {
            // Re-mint the bookmark off the resolved URL so persistence stays
            // valid; no UI prompt — the user already granted access once.
            if let fresh = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                var updated = observation
                updated.bookmarkData = fresh
                observationStore.save(updated)
            }
        }
        return url
    }

    /// User-facing re-grant prompt for legacy observations whose bookmark
    /// is missing. Pre-targets `NSOpenPanel` at the saved file so the user
    /// sees the file pre-selected — they just confirm.
    private func requestAccessRegrant(for observation: DownloadedObservation) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Re-grant Access")
        let filename = observation.filename
        panel.message = String(
            localized: "Verbinal needs your permission to re-open \(filename). Click Open to confirm."
        )
        panel.prompt = String(localized: "Open")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let url = URL(fileURLWithPath: observation.localPath)
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent

        guard panel.runModal() == .OK, let pickedURL = panel.url else { return }

        // Persist the freshly-granted bookmark so the next open works
        // without prompting.
        if let bookmark = try? pickedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            var updated = observation
            updated.bookmarkData = bookmark
            updated.localPath = pickedURL.path
            observationStore.save(updated)
        }

        let ext = pickedURL.pathExtension.lowercased()
        if FileHelper.isFITS(ext) {
            onOpenFile?(pickedURL)
        } else {
            NSWorkspace.shared.open(pickedURL)
        }
    }
    #endif

    // MARK: - Save Panel

    /// Result of a successful save: the on-disk URL plus a security-scoped
    /// bookmark so the sandbox can re-grant access on future launches.
    /// `bookmarkData` is `nil` only when bookmark capture itself failed —
    /// the file is saved, the open path will fall back to the re-grant flow.
    struct SaveResult {
        let url: URL
        let bookmarkData: Data?
    }

    #if os(macOS)
    @MainActor
    private func presentSavePanel(suggestedFilename: String, tempURL: URL) async -> SaveResult? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Observation")
        panel.message = String(localized: "Choose where to save the downloaded observation file.")

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

    /// Move the downloaded temp file into the user-picked location and
    /// capture a security-scoped bookmark while we still hold the
    /// `NSSavePanel`-issued grant. The bookmark is what lets `openFile`
    /// read the file in subsequent launches without prompting again.
    private func moveToFinal(from tempURL: URL, to saveURL: URL) -> SaveResult? {
        do {
            try FileHelper.moveReplacing(from: tempURL, to: saveURL)
            // Capture the bookmark *after* the move so the URL points at a
            // file that exists; capture failure is non-fatal — we still
            // keep the saved file and surface a re-grant prompt later.
            let bookmark = try? saveURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return SaveResult(url: saveURL, bookmarkData: bookmark)
        } catch {
            lastError = String(localized: "Failed to save: \(error.localizedDescription)")
            return nil
        }
    }
    #endif
}
