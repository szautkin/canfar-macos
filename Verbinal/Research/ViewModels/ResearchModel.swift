// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit
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
    /// Cuts part of an observation's file on CADC's side.
    let cutoutService: CutoutService
    let noteStore: ObservationNoteStore
    #if os(macOS)
    let exportService = ExportService()
    #endif

    var activeDownloads: [UUID: DownloadProgress] = [:]
    var selectedObservation: DownloadedObservation?
    var filterText = "" {
        didSet { if oldValue != filterText { scheduleNoteSearch() } }
    }
    /// PublisherIDs of observations whose NOTE text/tags match `filterText`,
    /// refreshed (debounced) off the render path so the FTS read never runs
    /// inside `filteredObservations`'s body evaluation.
    private(set) var noteMatchedPublisherIDs: Set<String> = []
    private var noteSearchTask: Task<Void, Never>?
    var lastError: String?
    var lastSuccess: String?

    /// Pending auto-dismiss task for toast-style status strings. A single handle
    /// ensures a new success/error replaces any in-flight dismissal, preventing an
    /// older task from clearing a newer message mid-stream.
    private var statusDismissTask: Task<Void, Never>?

    /// Called when the user opens a file; routes FITS/notebook files to in-app viewers.
    var onOpenFile: ((URL) -> Void)?

    // Defaults are constructed inline at the @MainActor init site
    // rather than as parameter defaults — parameter defaults are
    // evaluated in the caller's isolation context, and `@State
    // var researchModel = ResearchModel()` in a SwiftUI view
    // doesn't always inherit MainActor at the syntactic position
    // where defaults run, so the compiler refuses to call the
    // MainActor-isolated `ObservationStore.init`. Putting the
    // construction inside the body forces it onto the actor.
    init(observationStore: ObservationStore? = nil,
         downloadService: DownloadService = DownloadService(),
         noteStore: ObservationNoteStore? = nil) {
        self.observationStore = observationStore ?? ObservationStore()
        self.downloadService = downloadService
        self.noteStore = noteStore ?? ObservationNoteStore()
        self.cutoutService = CutoutService(downloads: downloadService)
    }

    var filteredObservations: [DownloadedObservation] {
        guard !filterText.isEmpty else { return observationStore.observations }
        let query = filterText.lowercased()
        return observationStore.observations.filter { obs in
            obs.targetName.lowercased().contains(query) ||
            obs.collection.lowercased().contains(query) ||
            obs.instrument.lowercased().contains(query) ||
            obs.observationID.lowercased().contains(query) ||
            // Also match what the user wrote ABOUT the observation (note FTS).
            noteMatchedPublisherIDs.contains(obs.publisherID)
        }
    }

    /// Debounced refresh of the note-text/tag FTS matches for `filterText`.
    private func scheduleNoteSearch() {
        noteSearchTask?.cancel()
        let query = filterText
        guard !query.isEmpty else { noteMatchedPublisherIDs = []; return }
        noteSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.noteMatchedPublisherIDs = Set(self.noteStore.searchPublisherIDs(matching: query))
        }
    }

    var activeDownloadList: [DownloadProgress] {
        Array(activeDownloads.values).sorted { $0.observation.downloadedAt > $1.observation.downloadedAt }
    }

    var hasActiveDownloads: Bool {
        activeDownloads.values.contains { $0.state == .downloading }
    }

    // MARK: - Download

    /// Download an observation from Search: fetch to temp, let the person
    /// choose where it goes, keep it in Research. With the search's cutout
    /// boxes ticked, only the part they ask for of the first file CADC can
    /// cut that way — or the whole file when none can.
    func downloadObservation(
        from result: SearchResult,
        columns: SearchResultColumns,
        dataLink: DataLinkResult?,
        searchCutout: SearchCutout = SearchCutout()
    ) async {
        let record = DownloadedObservation.from(result: result, columns: columns, localPath: "", dataLink: dataLink)
        if searchCutout.isRequested,
           let spec = await cutoutService.options(publisherID: record.publisherID).sources.lazy
               .compactMap({ searchCutout.spec(for: $0.file) }).first {
            await downloadCutout(of: record, spec)
        } else {
            await download(record)
        }
    }

    /// Fetch `record`'s file, let the person choose where it goes, and keep
    /// the record with it — the same record (id, notes) when Research
    /// already has the observation, as for one kept without its file.
    func download(_ record: DownloadedObservation) async {
        let downloadID = UUID()
        activeDownloads[downloadID] = DownloadProgress(id: downloadID, observation: record)
        lastError = nil
        lastSuccess = nil

        do {
            // Step 1: Download to temp — a cutout is cut again, not fetched whole.
            let tempURL: URL, suggestedFilename: String
            if let spec = record.cutout {
                tempURL = try await cutoutMaker(for: spec.cutBy).make(publisherID: record.publisherID, spec: spec)
                suggestedFilename = spec.fileName
            } else {
                (tempURL, suggestedFilename) = try await downloadService.downloadToTemp(publisherID: record.publisherID)
            }

            activeDownloads[downloadID]?.state = .completed

            // Step 2: Let user choose save location
            #if os(macOS)
            let saveResult = await presentSavePanel(suggestedFilename: suggestedFilename, tempURL: tempURL)
            #else
            let saveResult: SaveResult? = nil
            #endif

            guard let saveResult else {
                // User cancelled — clean up temp. A failure here (orphaned
                // temp file, read-only temp dir) is logged under category
                // Downloads rather than swallowed, but must not interrupt the
                // cancel flow, so we don't propagate it.
                await downloadService.deleteFileLoggingFailure(at: tempURL)
                activeDownloads.removeValue(forKey: downloadID)
                return
            }
            let finalURL = saveResult.url

            // Step 3: Get file size and store metadata (with the security-
            // scoped bookmark we captured during the save panel session).
            var observation = record
            observation.localPath = finalURL.path
            observation.bookmarkData = saveResult.bookmarkData
            observation.fileSize = await downloadService.fileSize(at: finalURL)
            observation.downloadedAt = Date()

            let stored = observationStore.save(observation)
            if selectedObservation?.recordKey == stored.recordKey { selectedObservation = stored }
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

    // MARK: - Cutouts

    /// The complete observation's file on this computer, readable.
    func localFile(publisherID: String) -> URL? {
        guard let record = observationStore.whole(publisherID: publisherID), record.isDownloaded else { return nil }
        #if os(macOS)
        if let url = resolvedURL(for: record) { return url }
        #endif
        return record.resolvedReadableURL
    }

    /// Who makes a cutout the given way.
    func cutoutMaker(for method: CutoutMethod) -> CutoutMaker {
        switch method {
        case .soda:
            return SodaCutoutMaker(service: cutoutService)
        case .local:
            return LocalCutoutMaker(file: { [weak self] publisherID in self?.localFile(publisherID: publisherID) })
        }
    }

    /// The ways an observation's files can be cut — the downloaded file on
    /// this computer first — and, when CADC can cut none, why.
    func cutoutSources(publisherID: String) async -> (sources: [any CutoutSource], problems: [String]) {
        let options = await cutoutService.options(publisherID: publisherID)
        return (CutoutSources.combine(local: localFile(publisherID: publisherID), soda: options.sources), options.problems)
    }

    /// Cut part of `details`' file on CADC's side and keep it in Research as
    /// a cutout of the observation, beside the complete one.
    func downloadCutout(of details: DownloadedObservation, _ spec: CutoutSpec) async {
        var record = details.withoutFile()
        record.id = UUID()
        record.cutout = spec
        record.agentAttribution = nil
        await download(record)
    }

    /// Keep an observation from Search in Research without its file.
    /// One already there is left as it is; returns whether it was added.
    @discardableResult
    func saveToResearch(from result: SearchResult, columns: SearchResultColumns, dataLink: DataLinkResult? = nil) -> Bool {
        observationStore.keep(DownloadedObservation.from(result: result, columns: columns, localPath: "", dataLink: dataLink)).added
    }

    /// Delete `observation`'s file from this computer and keep the
    /// observation — its details and notes — so Download brings it back.
    func removeFile(_ observation: DownloadedObservation) async throws {
        if let url = observation.resolvedReadableURL {
            try await downloadService.deleteFile(at: url)
        }
        if let kept = observationStore.forgetFile(of: observation.id), selectedObservation?.id == kept.id {
            selectedObservation = kept
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

    /// Research has this observation's file.
    func isDownloaded(publisherID: String) -> Bool {
        observationStore.whole(publisherID: publisherID)?.isDownloaded ?? false
    }

    /// Research keeps this observation, with its file or without.
    func isInResearch(publisherID: String) -> Bool {
        observationStore.contains(publisherID: publisherID)
    }

    // MARK: - File Management

    func deleteObservation(_ observation: DownloadedObservation) {
        // No file, nothing to delete — an empty path is the working directory.
        let url = observation.isDownloaded ? URL(fileURLWithPath: observation.localPath) : nil
        // Delete the file off the main actor (DownloadService is an actor),
        // then apply the @Observable state mutations explicitly back on the
        // MainActor. The closure already inherits this model's @MainActor
        // isolation, but the explicit annotation + [weak self] make the
        // hop-back unambiguous under strict concurrency and avoid a strong
        // self capture for the lifetime of the file delete.
        Task { @MainActor [weak self] in
            // The file may already be gone (handled as a no-op). Any genuine
            // deletion failure is logged under category Downloads for
            // diagnostics rather than surfaced to the user mid-delete.
            if let url { await self?.downloadService.deleteFileLoggingFailure(at: url) }
            guard let self else { return }
            // Remove metadata only after file deletion is attempted.
            self.observationStore.remove(observation)
            if self.selectedObservation?.id == observation.id {
                self.selectedObservation = nil
            }
        }
    }

    #if os(macOS)
    func revealInFinder(_ observation: DownloadedObservation) {
        guard observation.isDownloaded else { return }
        let url = resolvedURL(for: observation) ?? URL(fileURLWithPath: observation.localPath)
        // NSWorkspace runs in Finder's process and has its own grant — no
        // start/stopAccessingSecurityScopedResource needed here.
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    func openFile(_ observation: DownloadedObservation) {
        // Prefer the security-scoped bookmark — the only path that works for
        // files outside ~/Downloads after app restart. Fall back to a
        // path-only URL for legacy rows; if that fails the permission probe,
        // route through the re-grant flow.
        guard observation.isDownloaded else { return }
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
            // FITSViewerModel.open / .selectHDU each call
            // `start/stopAccessingSecurityScopedResource()` around their own
            // `Data(contentsOf:)` reads — they manage their own scope window.
            onOpenFile?(candidate)
        } else {
            // For external apps via NSWorkspace, hold scope around the
            // launch call so the kernel grant is active when AppKit hands
            // the URL to the other process.
            let didStart = candidate.startAccessingSecurityScopedResource()
            NSWorkspace.shared.open(candidate)
            if didStart { candidate.stopAccessingSecurityScopedResource() }
        }
    }

    /// Resolve `observation.bookmarkData` to a fresh security-scoped URL.
    /// Returns `nil` when:
    ///  • the observation has no bookmark (legacy save), or
    ///  • the bookmark was created on a different volume / removed file, or
    ///  • the system refuses to start the security scope.
    /// Stale bookmarks are silently re-created so the next save persists
    /// the refreshed token.
    ///
    /// **Important — scope handoff contract:**
    /// This function returns the resolved URL *without* an active scope.
    /// Callers must call `startAccessingSecurityScopedResource()` (paired
    /// with stop) around any actual file read. The internal scope pair here
    /// is a *liveness probe* only: it confirms the bookmark resolves and
    /// the kernel will accept a future start; it doesn't keep the URL
    /// readable across the function boundary. Holding scope until the
    /// async caller finishes would require a closure or a `ScopedAccess`
    /// reference type — instead we let the FITS viewer / NSWorkspace
    /// callers manage scope explicitly (see ``openFile``).
    private func resolvedURL(for observation: DownloadedObservation) -> URL? {
        guard let data = observation.bookmarkData else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }

        // Liveness probe: if start fails, the bookmark is unusable (volume
        // missing, file removed, sandbox revoked the grant). Treat as no
        // bookmark and let the legacy / re-grant fallback take over.
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

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
