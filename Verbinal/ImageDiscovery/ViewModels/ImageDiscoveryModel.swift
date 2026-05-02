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
        /// Cached failure with display message + when.
        case failed(message: String, attemptedAt: Date)
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

    init(coordinator: ImageDiscoveryCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Open / close lifecycle

    /// Sheet just appeared: load the catalogue, hydrate row states
    /// from cache, kick off discovery for everything not yet cached.
    func onAppear(catalogue: [ParsedImage]) async {
        allKnownImages = catalogue
        await refreshFromCache()
        await runDiscovery()
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
            rowStates[id] = .failed(message: err.displayMessage, attemptedAt: Date())
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

    /// Drop and re-run discovery for a single image. The user
    /// triggers this from the row's "Rediscover" affordance
    /// (Phase 5 wires the icon, the path is here today so the
    /// coordinator path is exercised).
    func rediscover(_ imageID: String) async {
        rowStates[imageID] = .running
        do {
            let manifest = try await coordinator.rediscover(imageID)
            rowStates[imageID] = .discovered(manifest)
            mergeIntoAllPackages(manifest)
        } catch let err as ImageDiscoveryError {
            rowStates[imageID] = .failed(message: err.displayMessage, attemptedAt: Date())
            bannerMessage = "Rediscover \(imageID): \(err.displayMessage)"
        } catch {
            rowStates[imageID] = .failed(message: error.localizedDescription, attemptedAt: Date())
        }
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
        case .failure(_, _, let msg, let when)?:
            return .failed(message: msg, attemptedAt: when)
        }
    }
}
