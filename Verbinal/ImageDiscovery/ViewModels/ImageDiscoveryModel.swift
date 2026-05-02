// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// View-model for the Image Discovery sheet.
///
/// Owns the state the SwiftUI views bind to: the current
/// `PackageQuery`, the per-image discovery state for the right
/// pane's row indicators, the aggregated `AllPackages` snapshot
/// that drives the left pane's checkbox sections, and the search
/// text that filters both panes.
///
/// Discovery work runs on the actor-isolated coordinator; this
/// model is the bridge that translates streaming DiscoveryEvents
/// into @Observable property mutations the UI can render.
@Observable
@MainActor
final class ImageDiscoveryModel {

    /// Per-row UI state on the right pane.
    enum RowState: Sendable, Equatable {
        /// No outcome cached, no probe running.
        case neverDiscovered
        /// Probe job submitted; polling underway.
        case running
        /// Cached success — manifest available.
        case discovered(ImageManifest)
        /// Cached failure with display message + when. `jobID` is
        /// the Skaha session id of the probe that failed (when
        /// applicable) so the UI can offer "View logs".
        case failed(message: String, attemptedAt: Date, jobID: String?)
    }

    // MARK: - Inputs

    private let coordinator: ImageDiscoveryCoordinator

    // MARK: - Public observable state

    /// Every image id the launcher knows about (catalog from
    /// ImageService, all types — not just headless). Drives the
    /// right pane.
    private(set) var allKnownImages: [ParsedImage] = []

    /// Per-image row state, keyed by image id.
    private(set) var rowStates: [String: RowState] = [:]

    /// Aggregated package snapshot — feeds the left pane.
    private(set) var allPackages: AllPackages = AllPackages()

    /// User-edited query state. Setters trigger re-render via
    /// `@Observable`.
    var query: PackageQuery = PackageQuery()

    /// Filter text (single bar, scoped to both panes).
    var searchText: String = ""

    /// Image id the user has highlighted in the right pane.
    var selectedImageID: String?

    /// True while a `discoverAll` stream is in flight.
    private(set) var isDiscoveryRunning: Bool = false

    /// Most recent error to surface in a banner; cleared on
    /// retry / close.
    var bannerMessage: String?

    /// When non-nil, the discovery sheet presents the probe-logs
    /// sheet for this Skaha session id. Setter triggered by the
    /// "View logs" button on a failed row.
    var jobIDForLogsSheet: String?

    init(coordinator: ImageDiscoveryCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Open / close lifecycle

    /// Sheet just appeared: load the catalogue and hydrate row
    /// states from cache. **Does NOT auto-start discovery** — the
    /// user triggers each probe explicitly via the per-row Discover
    /// button. Auto-running was reverted because (a) it commits real
    /// Skaha resources without explicit consent, and (b) failures
    /// across the catalogue cluster up faster than the user can
    /// triage.
    func onAppear(catalogue: [ParsedImage]) async {
        allKnownImages = catalogue
        await refreshFromCache()
    }

    /// Sheet about to dismiss. The coordinator's polling continues
    /// in the background — we just stop driving the UI.
    func onDisappear() {
        // Cancellation of the discovery stream happens automatically
        // when the wrapping Task is cancelled (caller in the View).
    }

    // MARK: - Cache reload

    /// Re-pull cached outcomes and re-aggregate AllPackages. Called
    /// on appear and after each completed discovery so the UI
    /// reflects the on-disk state.
    func refreshFromCache() async {
        var states: [String: RowState] = [:]
        for img in allKnownImages {
            let outcome = await coordinator.outcome(for: img.id)
            states[img.id] = Self.rowState(from: outcome)
        }
        rowStates = states
        allPackages = await coordinator.allPackages()
    }

    // MARK: - Discovery driver

    /// Stream discoveries for every image we don't have cached yet.
    /// Cache hits don't generate work; misses go through bounded-
    /// concurrency probes via the coordinator.
    func runDiscovery() async {
        guard !isDiscoveryRunning else { return }
        isDiscoveryRunning = true
        defer { isDiscoveryRunning = false }

        let ids = allKnownImages.map(\.id)
        for await event in coordinator.discoverAll(ids) {
            apply(event: event)
        }
        // Re-aggregate package snapshot one final time (cheap).
        allPackages = await coordinator.allPackages()
    }

    private func apply(event: DiscoveryEvent) {
        switch event {
        case .started(let id):
            rowStates[id] = .running
        case .completed(let id, let manifest):
            rowStates[id] = .discovered(manifest)
            // Aggregate packages incrementally so the LEFT pane fills
            // in as discoveries complete, not just at the end.
            mergeIntoAllPackages(manifest)
        case .failed(let id, let err):
            // The coordinator persisted the cached failure already;
            // re-read so we get the jobID it captured (we don't
            // have direct access to the jobID from the streaming
            // event, but the cache does).
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.coordinator.outcome(for: id)
                if case .failure(_, _, _, let when, let jobID) = outcome {
                    self.rowStates[id] = .failed(
                        message: err.displayMessage,
                        attemptedAt: when,
                        jobID: jobID
                    )
                } else {
                    self.rowStates[id] = .failed(
                        message: err.displayMessage,
                        attemptedAt: Date(),
                        jobID: nil
                    )
                }
            }
        }
    }

    private func mergeIntoAllPackages(_ m: ImageManifest) {
        if m.osFamily != "unknown" {
            allPackages.osFamilies.insert(m.osFamily)
            if m.osVersion != "unknown" {
                allPackages.osVersionsByFamily[m.osFamily, default: []].insert(m.osVersion)
            }
        }
        for p in m.dpkgPackages   { allPackages.dpkg.insert(p.name) }
        for p in m.rpmPackages    { allPackages.rpm.insert(p.name) }
        for p in m.apkPackages    { allPackages.apk.insert(p.name) }
        for p in m.pythonPackages { allPackages.python.insert(p.name) }
        for p in m.rPackages      { allPackages.r.insert(p.name) }
    }

    // MARK: - Per-image actions

    /// User-triggered probe for one image. If the image already has
    /// a cached manifest this short-circuits and just re-reads it
    /// (matches `coordinator.discover` semantics — `force: false`).
    /// Use `rediscover(_:)` to force a fresh probe regardless of
    /// cache.
    func discover(_ imageID: String) async {
        rowStates[imageID] = .running
        do {
            let manifest = try await coordinator.discover(imageID)
            rowStates[imageID] = .discovered(manifest)
            mergeIntoAllPackages(manifest)
        } catch let err as ImageDiscoveryError {
            await refreshFailureRow(imageID: imageID, message: err.displayMessage)
        } catch {
            await refreshFailureRow(imageID: imageID, message: error.localizedDescription)
        }
    }

    /// Force-rediscover: drops the cached entry and runs a fresh
    /// probe even if the image already has a manifest.
    func rediscover(_ imageID: String) async {
        rowStates[imageID] = .running
        do {
            let manifest = try await coordinator.rediscover(imageID)
            rowStates[imageID] = .discovered(manifest)
            mergeIntoAllPackages(manifest)
        } catch let err as ImageDiscoveryError {
            await refreshFailureRow(imageID: imageID, message: err.displayMessage)
            bannerMessage = "Rediscover \(imageID): \(err.displayMessage)"
        } catch {
            await refreshFailureRow(imageID: imageID, message: error.localizedDescription)
        }
    }

    /// Pull the cached failure outcome for `imageID` and update
    /// `rowStates` with the captured jobID so "View logs" works.
    private func refreshFailureRow(imageID: String, message: String) async {
        let outcome = await coordinator.outcome(for: imageID)
        if case .failure(_, _, _, let when, let jobID) = outcome {
            rowStates[imageID] = .failed(message: message, attemptedAt: when, jobID: jobID)
        } else {
            rowStates[imageID] = .failed(message: message, attemptedAt: Date(), jobID: nil)
        }
    }

    // MARK: - Clearing failures

    /// Number of rows currently in the failed state. Drives the
    /// "Clear all errors (N)" button visibility / label in the
    /// sheet header.
    var failedCount: Int {
        rowStates.values.reduce(into: 0) { acc, state in
            if case .failed = state { acc += 1 }
        }
    }

    /// Drop the cached failure for `imageID` and reset the row to
    /// never-discovered. Doesn't re-probe — the user explicitly
    /// chose to dismiss without retrying.
    func clearFailure(_ imageID: String) async {
        do {
            try await coordinator.invalidate(imageID: imageID)
            rowStates[imageID] = .neverDiscovered
        } catch {
            bannerMessage = "Couldn't clear \(imageID): \(error.localizedDescription)"
        }
    }

    /// Drop every cached failure outcome in one shot. Successful
    /// manifests are kept. Used by the sheet header's "Clear all
    /// errors" button when the user wants to wipe the slate after
    /// a bad batch (e.g. before retrying a different image set).
    func clearAllFailures() async {
        do {
            try await coordinator.clearFailures()
            for (id, state) in rowStates {
                if case .failed = state {
                    rowStates[id] = .neverDiscovered
                }
            }
        } catch {
            bannerMessage = "Couldn't clear failures: \(error.localizedDescription)"
        }
    }

    // MARK: - Diagnostics for failed rows

    /// Fetch the container stdout/stderr for a probe job. UI calls
    /// this when the user clicks "View logs" on a failed row.
    func fetchLogs(jobID: String) async throws -> String {
        try await coordinator.fetchLogs(jobID: jobID)
    }

    /// Fetch the Kubernetes-level events for a probe job. Useful
    /// when a job sat in Pending forever or hit an ImagePullBackOff.
    func fetchEvents(jobID: String) async throws -> String {
        try await coordinator.fetchEvents(jobID: jobID)
    }

    // MARK: - Filtering

    /// Image ids that satisfy the current query *and* the search
    /// text (which scopes by image label / id substring on the
    /// right pane).
    var filteredImageIDs: [String] {
        let cached = allKnownImages.compactMap { img -> String? in
            // Only successful manifests can satisfy a non-empty
            // query — failures and pending have no manifest to match.
            if case .discovered(let m) = rowStates[img.id] {
                return query.isEmpty || query.matches(m) ? img.id : nil
            }
            // For empty query, include everything we know about
            // (running / failed / never-discovered all show up so
            // the user can see progress).
            return query.isEmpty ? img.id : nil
        }
        // Apply search-text on top.
        guard !searchText.isEmpty else { return cached }
        let needle = searchText.lowercased()
        return cached.filter { id in
            id.lowercased().contains(needle) ||
            allKnownImages.first(where: { $0.id == id })?.label.lowercased().contains(needle) == true
        }
    }

    /// Project-grouped view of `filteredImageIDs` for the right pane
    /// `Section` headers.
    var filteredImagesByProject: [(project: String, images: [ParsedImage])] {
        let allowed = Set(filteredImageIDs)
        let group = Dictionary(grouping: allKnownImages.filter { allowed.contains($0.id) },
                               by: { $0.project })
        return group
            .map { (project: $0.key, images: $0.value.sorted { $0.label < $1.label }) }
            .sorted { $0.project < $1.project }
    }

    // MARK: - Row state from outcome

    private static func rowState(from outcome: LastOutcome?) -> RowState {
        switch outcome {
        case .none: return .neverDiscovered
        case .success(let m)?: return .discovered(m)
        case .failure(_, _, let msg, let when, let jobID)?:
            return .failed(message: msg, attemptedAt: when, jobID: jobID)
        }
    }
}
