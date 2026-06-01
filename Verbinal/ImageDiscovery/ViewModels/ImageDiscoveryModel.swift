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

    /// Category of the cached failure for each `.failed` row,
    /// keyed by image id. Populated alongside `rowStates` so the
    /// row template can render category-aware UI (different
    /// label / colour for `jobTimedOut` vs `jobSubmitFailed` vs
    /// `manifestParseFailed`) without re-querying the cache on
    /// every paint. Entries are removed when the row is cleared
    /// or transitions to a non-failure state.
    /// 2026-05-21: Phase 2 of the UX-audit follow-up — adds
    /// "what kind of failure" granularity without breaking the
    /// existing `RowState.failed` case shape.
    private(set) var failureCategories: [String: LastOutcome.FailureCategory] = [:]

    /// Aggregated package snapshot — feeds the left pane.
    private(set) var allPackages: AllPackages = AllPackages()

    /// User-edited query state. Setters trigger re-render via
    /// `@Observable`.
    var query: PackageQuery = PackageQuery()

    /// Search text scoped to the LEFT pane — narrows the list of
    /// package / OS-version checkboxes. Doesn't affect which images
    /// appear in the right pane.
    var packageSearchText: String = ""

    /// Search text scoped to the RIGHT pane — narrows the image
    /// rows by id / label / tag. Doesn't affect the package
    /// checkbox list on the left.
    var imageSearchText: String = ""

    /// Backwards-compat alias kept so any caller that expected the
    /// pre-split single field continues to read the LEFT pane's
    /// search. Prefer `packageSearchText` / `imageSearchText` for
    /// new code.
    var searchText: String {
        get { packageSearchText }
        set { packageSearchText = newValue }
    }

    /// Session-type filter for the right pane (`nil` = all types).
    /// ANDs with the package query + image search. Cache-only images
    /// (no known `types`) are never hidden by it — see `filteredImageIDs`.
    var typeFilter: String?

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

    /// When non-nil, the discovery sheet presents the failure-detail
    /// sheet — full Skaha response, scrollable and copyable. Used
    /// for failures that have NO `jobID` (e.g. the K8s race after
    /// retry exhaustion), where `ProbeLogsSheet` can't open because
    /// it's keyed on a Skaha session id we never received.
    var failureDetailForSheet: FailureDetail?

    /// When non-nil, the discovery sheet presents the
    /// `ManifestDetailSheet` for this image's cached manifest.
    /// Set by the per-row "info" icon on a `.discovered` row.
    /// 2026-05-21 Phase 3: lets the picky-astronomer user verify
    /// primary probe data (packages, capabilities, OS detail)
    /// without digging through the on-disk JSON cache.
    var manifestDetailForSheet: ImageManifest?

    /// Live count of probes the coordinator currently has in
    /// flight. Survives sheet open/close: subscribed via
    /// `coordinator.inFlightCountChanges()` for the model's
    /// lifetime, so the LaunchFormView's magnifier badge can
    /// show "N probes running" even while the discovery sheet
    /// is dismissed. 2026-05-19 addition closing the
    /// "Close-button + visible background-job tracking" pair.
    private(set) var inFlightProbeCount: Int = 0

    /// Snapshot of one cached failure rendered in the detail sheet.
    /// Carries everything the sheet needs without re-querying state
    /// while the sheet is open.
    struct FailureDetail: Equatable, Identifiable {
        let id = UUID()
        let imageID: String
        let message: String
        let attemptedAt: Date
        let jobID: String?
    }

    /// Long-lived subscription to coordinator in-flight count
    /// changes. Started in init, cancelled in deinit. Lives across
    /// every sheet open/close cycle so the magnifier badge in the
    /// launch form stays accurate from the moment the model is
    /// constructed.
    ///
    /// `nonisolated(unsafe)` — written exactly once during the
    /// MainActor init and read exactly once from the nonisolated
    /// deinit. No concurrent access; the "unsafe" annotation is
    /// the standard escape hatch for this single-writer / single-
    /// reader pattern. Required (not just stylistic) here because
    /// the enclosing class is `@Observable`, and Observation's macro
    /// expansion requires `nonisolated(unsafe)` for mutable stored
    /// properties that step outside the actor's isolation.
    private nonisolated(unsafe) var inFlightCountSubscription: Task<Void, Never>?

    init(coordinator: ImageDiscoveryCoordinator) {
        self.coordinator = coordinator
        // Bind `inFlightProbeCount` to the coordinator's stream
        // for the model's entire lifetime. `[weak self]` so the
        // task self-terminates if the model is deallocated; the
        // stream's `.onTermination` callback cleans up the
        // coordinator-side continuation in that case.
        let stream = coordinator.inFlightCountChanges()
        inFlightCountSubscription = Task { [weak self] in
            for await count in stream {
                guard let self else { return }
                self.inFlightProbeCount = count
            }
        }
    }

    deinit {
        // Synchronous cancel of the captured Task reference. The
        // stream's `.onTermination` then unregisters the
        // coordinator-side continuation. No MainActor hop needed
        // — Task.cancel() is nonisolated.
        inFlightCountSubscription?.cancel()
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
        // Cache-fallback: when the live Skaha image catalogue load
        // failed (timeout, auth blip, network), `catalogue` arrives
        // empty even though we may have cached manifests on disk.
        // Surface those cached images in the right pane so the user
        // isn't staring at an empty modal next to a populated left
        // pane. Synthesize `ParsedImage` rows by parsing the raw
        // ids — `types` defaults to empty since we don't know them
        // without the live catalogue, but ID + label are enough for
        // browsing and re-discovery.
        if allKnownImages.isEmpty {
            await hydrateFromCacheOnly()
        }
        // 2026-05-21: re-check VOSpace for any image still
        // showing a `jobTimedOut` failure from a prior attempt
        // — the probe may have completed and written the
        // manifest after the foreground polling gave up but
        // before the coordinator's grace task could pick it up
        // (or after the app was last quit). Silent recovery —
        // surfaces a banner only when something flipped from
        // failed to discovered, otherwise no UI noise.
        await recoverTimedOutEntries()
    }

    /// Re-check VOSpace for every image that's currently
    /// marked failed with `category: .jobTimedOut`. Promotes
    /// each recovered row to `.discovered(manifest)` and
    /// merges the manifest into `allPackages` so the left-pane
    /// filter chips fill in for free.
    private func recoverTimedOutEntries() async {
        var recovered: [String] = []
        for id in rowStates.keys {
            guard case .failed = rowStates[id] else { continue }
            guard case .failure(_, .jobTimedOut, _, _, _) = await coordinator.outcome(for: id) else {
                continue
            }
            if let manifest = await coordinator.recoverFromVOSpaceIfPresent(imageID: id) {
                rowStates[id] = .discovered(manifest)
                mergeIntoAllPackages(manifest)
                recovered.append(id)
            }
        }
        if !recovered.isEmpty {
            let n = recovered.count
            bannerMessage = "Recovered \(n) manifest\(n == 1 ? "" : "s") that completed in the background after the prior attempt's polling deadline."
        }
    }

    /// Build `allKnownImages` purely from cached manifest ids when
    /// the live catalogue isn't available. Everything else (row
    /// states, allPackages) gets refreshed against the now-populated
    /// id list so the right pane mirrors what the cache knows.
    private func hydrateFromCacheOnly() async {
        let cachedIDs = await coordinator.knownImages()
        guard !cachedIDs.isEmpty else { return }
        allKnownImages = cachedIDs.map {
            ImageParser.parse(RawImage(id: $0, types: []))
        }
        await refreshFromCache()
        bannerMessage = "Live image catalogue unavailable — showing \(cachedIDs.count) image\(cachedIDs.count == 1 ? "" : "s") from local cache."
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
        var categories: [String: LastOutcome.FailureCategory] = [:]
        for img in allKnownImages {
            let outcome = await coordinator.outcome(for: img.id)
            states[img.id] = Self.rowState(from: outcome)
            if case .failure(_, let category, _, _, _) = outcome {
                categories[img.id] = category
            }
        }
        rowStates = states
        failureCategories = categories
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
            // Cleared on transition out of .failed — otherwise a
            // stale "what kind of failure" badge would linger
            // after a successful re-probe.
            failureCategories.removeValue(forKey: id)
            // Aggregate packages incrementally so the LEFT pane fills
            // in as discoveries complete, not just at the end.
            mergeIntoAllPackages(manifest)
        case .failed(let id, let err):
            // The coordinator persisted the cached failure already;
            // re-read so we get the jobID + category it captured.
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.coordinator.outcome(for: id)
                if case .failure(_, let category, _, let when, let jobID) = outcome {
                    self.rowStates[id] = .failed(
                        message: err.displayMessage,
                        attemptedAt: when,
                        jobID: jobID
                    )
                    self.failureCategories[id] = category
                } else {
                    self.rowStates[id] = .failed(
                        message: err.displayMessage,
                        attemptedAt: Date(),
                        jobID: nil
                    )
                    self.failureCategories[id] = err.cacheCategory
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
        if case .failure(_, let category, _, let when, let jobID) = outcome {
            rowStates[imageID] = .failed(message: message, attemptedAt: when, jobID: jobID)
            failureCategories[imageID] = category
        } else {
            rowStates[imageID] = .failed(message: message, attemptedAt: Date(), jobID: nil)
            failureCategories.removeValue(forKey: imageID)
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
            failureCategories.removeValue(forKey: imageID)
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
                    failureCategories.removeValue(forKey: id)
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
        // Apply image-scoped search on top.
        let searched: [String]
        if imageSearchText.isEmpty {
            searched = cached
        } else {
            let needle = imageSearchText.lowercased()
            searched = cached.filter { id in
                id.lowercased().contains(needle) ||
                allKnownImages.first(where: { $0.id == id })?.label.lowercased().contains(needle) == true
            }
        }
        // Session-type filter. Unknown-type (cache-only) images are never
        // hidden — they bucket under "All" so a Skaha-catalogue outage
        // doesn't make them vanish when a specific type is selected.
        guard let type = typeFilter else { return searched }
        return searched.filter { id in
            guard let img = allKnownImages.first(where: { $0.id == id }) else { return false }
            return img.types.isEmpty || img.types.contains(type)
        }
    }

    /// Session types present across the catalogue, in canonical UI order
    /// (then any extras alphabetically). Drives the type filter control.
    var availableTypes: [String] {
        let present = Set(allKnownImages.flatMap { $0.types })
        let canonical = ["notebook", "desktop", "carta", "headless", "contributed", "firefly", "desktop-app"]
        let ordered = canonical.filter { present.contains($0) }
        let extras = present.subtracting(canonical).sorted()
        return ordered + extras
    }

    /// Every successfully-discovered manifest in row state. Used by
    /// `availableValues(for:)` and the chips/filter logic that
    /// needs to look at actual package contents, not just the
    /// catalogue's all-known values.
    var allDiscoveredManifests: [ImageManifest] {
        rowStates.values.compactMap {
            if case .discovered(let m) = $0 { return m } else { return nil }
        }
    }

    /// Set of values for `category` that, if added to the query,
    /// would still yield at least one matching manifest given the
    /// CURRENT settings of every OTHER category. The left pane
    /// uses this to disable checkboxes whose values are guaranteed
    /// to make the result empty — e.g. once `OS = centos` is
    /// ticked, `Python = numpy` should grey out unless at least
    /// one centos manifest has numpy.
    func availableValues(for category: PackageQuery.Category) -> Set<String> {
        let scoped = query.dropping(category)
        var available: Set<String> = []
        for m in allDiscoveredManifests where scoped.matches(m) {
            switch category {
            case .osFamily:
                if m.osFamily != "unknown" { available.insert(m.osFamily) }
            case .osVersion:
                if m.osVersion != "unknown" { available.insert(m.osVersion) }
            case .python:       available.formUnion(m.pythonPackages.map(\.name))
            case .r:            available.formUnion(m.rPackages.map(\.name))
            case .dpkg:         available.formUnion(m.dpkgPackages.map(\.name))
            case .rpm:          available.formUnion(m.rpmPackages.map(\.name))
            case .apk:          available.formUnion(m.apkPackages.map(\.name))
            case .capabilities: available.formUnion(m.capabilities)
            }
        }
        return available
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

    // MARK: - UX helpers (timestamp + category labels)

    /// Short human label for a failure category. Used by the
    /// MatchingImagesPane row to render category-aware status
    /// chips ("Timed out" vs "Submit failed" vs "Auth"). Static
    /// so the View can call it without holding a model reference.
    /// Localisation hook lives here too — the View just renders
    /// the returned string.
    nonisolated static func categoryLabel(_ category: LastOutcome.FailureCategory) -> String {
        switch category {
        case .jobSubmitFailed:    return "Submit failed"
        case .jobTimedOut:        return "Timed out"
        case .manifestFetchFailed: return "No manifest"
        case .manifestParseFailed: return "Bad manifest"
        case .cancelled:          return "Cancelled"
        case .unknown:            return "Failed"
        }
    }

    /// Short relative-time label for an attempt or capture
    /// timestamp ("3 min ago", "yesterday", "May 14").
    /// Time-bounded to keep the row compact — anything older
    /// than 14 days falls back to a short absolute date so the
    /// user doesn't see "3 weeks ago" when "May 1" would fit
    /// the same width.
    nonisolated static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        // Future / clock skew → just show "now"
        if elapsed < 30 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3_600 {
            let m = Int(elapsed / 60)
            return "\(m)m ago"
        }
        if elapsed < 86_400 {
            let h = Int(elapsed / 3_600)
            return "\(h)h ago"
        }
        if elapsed < 14 * 86_400 {
            let d = Int(elapsed / 86_400)
            return "\(d)d ago"
        }
        // Falls back to a short absolute date format for older
        // timestamps. Locale-respecting via DateFormatter.
        return Self.absoluteFormatter.string(from: date)
    }

    nonisolated private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// True when a failure with the given attempt time + category
    /// might still be recovered by the coordinator's background
    /// grace-poll task. The UI renders these rows with a "checking
    /// in background" hint instead of a hard "failed" pill — the
    /// manifest may yet land at VOSpace and flip the row green on
    /// the next sheet open.
    ///
    /// Conservative window: 10 minutes from the attempt timestamp,
    /// matching the coordinator's default `graceJobTimeout`. A
    /// fully accurate signal would require the model to know the
    /// coordinator's grace budget — overkill for now; the time-
    /// since-attempt heuristic is right ~always.
    nonisolated static func isLikelyStillRecovering(
        category: LastOutcome.FailureCategory,
        attemptedAt: Date,
        now: Date = Date()
    ) -> Bool {
        guard category == .jobTimedOut else { return false }
        return now.timeIntervalSince(attemptedAt) < 10 * 60
    }
}
