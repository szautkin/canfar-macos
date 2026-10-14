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
    /// An observation's files, one by one (plan 34 F).
    let files: ResearchFiles
    /// Its files between this Mac and the person's storage.
    let transfer: ResearchFileTransfer
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

    /// Where a record just added gets its details (set by the app, one
    /// archive client for Research and the check of older records).
    var archive: (any ArchiveObservations)?
    /// Where the lookup of a record just added shows.
    @ObservationIgnored var tasks: TaskRegistry = .shared

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
        self.files = ResearchFiles(store: self.observationStore, downloads: downloadService)
        self.transfer = ResearchFileTransfer(store: self.observationStore, files: self.files, downloads: downloadService)
        files.onNewRecord = { [weak self] record in self?.completeFromArchive(record) }
        let store = self.observationStore
        FileOrigins.shared.research = { [weak store] url in store?.portableIdentity(of: url) }
        ResultDestination.shared.sent = { [weak store] url, path in store?.noteInStorage(url, at: path) }
    }

    var filteredObservations: [DownloadedObservation] {
        guard !filterText.isEmpty else { return observationStore.observations }
        let filter = ResearchFilter(filterText, noteMatches: noteMatchedPublisherIDs)
        return observationStore.observations.filter(filter.keeps)
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

    /// Fetch `record`'s file into the download folder, and keep the record
    /// with it — the same record (id, notes) when Research already has the
    /// observation, as for one kept without its file. No question: the
    /// person sees and chooses the folder (plan 34 F).
    func download(_ record: DownloadedObservation) async {
        let downloadID = UUID()
        activeDownloads[downloadID] = DownloadProgress(id: downloadID, observation: record)
        lastError = nil
        lastSuccess = nil

        do {
            // Step 1: Download to temp — a cutout is cut again, not fetched whole.
            let tempURL: URL, suggestedFilename: String
            var companions: [URL] = []
            if let spec = record.cutout {
                let files = try await cutoutMaker(for: spec.cutBy).make(publisherID: record.publisherID, spec: spec)
                (tempURL, companions) = (files.cutout, files.companions)
                suggestedFilename = spec.fileName
            } else {
                (tempURL, suggestedFilename) = try await downloadService.downloadToTemp(publisherID: record.publisherID)
            }

            activeDownloads[downloadID]?.state = .completed

            // Step 2: into the download folder, never over another file.
            let placed = try await DownloadPlacement.place(tempURL, named: suggestedFilename, downloads: downloadService)
            let companionNote = placeCompanions(companions, beside: URL(fileURLWithPath: placed.localPath))

            // Step 3: keep it, with the bookmark that opens it again.
            var observation = record
            observation.localPath = placed.localPath
            observation.bookmarkData = placed.bookmark
            observation.fileSize = placed.size
            observation.downloadedAt = Date()

            let stored = observationStore.save(observation)
            if selectedObservation?.recordKey == stored.recordKey { selectedObservation = stored }
            completeFromArchive(stored)
            lastSuccess = String(localized: "Saved in \(DownloadsFolder.url.lastPathComponent): \((placed.localPath as NSString).lastPathComponent)") + (companionNote.map { " — \($0)" } ?? "")

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
        return (CutoutSources.combine(local: localFile(publisherID: publisherID), soda: options.sources, artifacts: options.artifacts),
                options.problems)
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

    /// A cutout's companions, beside it — or in Downloads when the sandbox
    /// grants only the file the person chose. Says where they went when
    /// that is not beside it.
    private func placeCompanions(_ companions: [URL], beside cutout: URL) -> String? {
        var elsewhere: [String] = []
        for companion in companions {
            let name = companion.lastPathComponent
            if let placed = try? DownloadsFolder.move(companion, named: name, into: cutout.deletingLastPathComponent()) {
                ResultDestination.shared.kept(placed, area: .research)
            } else if let placed = try? DownloadsFolder.move(companion, named: name) {
                ResultDestination.shared.kept(placed, area: .research)
                elsewhere.append(placed.lastPathComponent)
            }
        }
        return elsewhere.isEmpty ? nil : String(localized: "\(elsewhere.joined(separator: ", ")) saved in Downloads")
    }

    /// Keep an observation from Search in Research without its file.
    /// One already there is left as it is; returns whether it was added.
    @discardableResult
    func saveToResearch(from result: SearchResult, columns: SearchResultColumns, dataLink: DataLinkResult? = nil) -> Bool {
        let kept = observationStore.keep(DownloadedObservation.from(result: result, columns: columns, localPath: "", dataLink: dataLink))
        if kept.added { completeFromArchive(kept.record) }
        return kept.added
    }

    /// A record just added, brought up to the archive in the background, on
    /// the activity bar: one added from Search kept only what the search row
    /// had, and stayed blank where it had nothing (plan 19 R1).
    func completeFromArchive(_ record: DownloadedObservation) {
        guard let archive else { return }
        let name = record.observationID.isEmpty ? record.publisherID : record.observationID
        let tasks = tasks
        Task { [weak self] in
            let observation = await tasks.track(.research, String(localized: "Archive details of \(name)")) { _ in
                await archive.observation(publisherID: record.publisherID, within: ResearchRecordRepair.requestSeconds)
            }
            guard let self else { return }
            if self.observationStore.complete(recordID: record.id, from: observation),
               self.selectedObservation?.id == record.id {
                self.selectedObservation = self.observationStore.observations.first { $0.id == record.id }
            }
        }
    }

    /// Delete `observation`'s file from this computer and keep the
    /// observation — its details and notes — so Download brings it back.
    func removeFile(_ observation: DownloadedObservation) async throws {
        try await removeFile(named: observation.mainFile.name, of: observation)
    }

    /// Delete `observation`'s file `name` — one of its files, or its main
    /// one — from this computer, and keep the observation (plan 34 F).
    func removeFile(named name: String, of observation: DownloadedObservation) async throws {
        if let kept = try await files.remove(fileNamed: name, of: observation.id), selectedObservation?.id == kept.id {
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
        // Its files, the main one and the others (plan 34 F); an empty path
        // is the working directory, never one of them.
        let urls = observation.localFiles.compactMap { $0.readableURL ?? $0.url }
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
            for url in urls { await self?.downloadService.deleteFileLoggingFailure(at: url) }
            guard let self else { return }
            // Remove metadata only after file deletion is attempted.
            self.observationStore.remove(observation)
            if self.selectedObservation?.id == observation.id {
                self.selectedObservation = nil
            }
        }
    }

    #if os(macOS)
    /// Opens one of a record's files (plan 34 F) as `openFile` opens its
    /// main one: a FITS file in Verbinal, anything else in its app.
    func open(_ file: KeptFile) {
        guard file.local.exists else { return }
        let url = file.local.bookmarked()?.url ?? file.local.readableURL ?? URL(fileURLWithPath: file.localPath)
        if FileHelper.isFITS(url.pathExtension.lowercased()) {
            onOpenFile?(url)
        } else {
            let didStart = url.startAccessingSecurityScopedResource()
            NSWorkspace.shared.open(url)
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Shows one of a record's files in the Finder.
    func reveal(_ file: KeptFile) {
        let url = file.local.bookmarked()?.url ?? file.local.readableURL ?? URL(fileURLWithPath: file.localPath)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

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
        guard let (url, stale) = observation.bookmarkedFile() else { return nil }

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

        guard UIPresentations.shared.runModal(panel, "Re-grant Access") == .OK, let pickedURL = panel.url else { return }

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
}
