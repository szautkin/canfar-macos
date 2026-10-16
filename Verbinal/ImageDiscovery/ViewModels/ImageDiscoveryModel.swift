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

    /// The catalogue, a discovery run, and the person's other actions, each
    /// a Phase; and what a recovery found (plan 38; ImageDiscoveryModel+State).
    var catalogue: Phase<Date> = .idle
    var discovery: Phase<Date> = .idle
    var actions: Phase<Date> = .idle
    var recoveryNote: String?

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
    /// Owns the long-lived subscription Task. See ``InFlightSubscription``:
    /// holding the Task in a tiny non-isolated helper (instead of a
    /// `nonisolated(unsafe) var` on this `@Observable @MainActor` type) lets
    /// the model store it as a plain `let` with no concurrency escape hatch.
    /// The Task can't itself be a stored `let` because its `[weak self]`
    /// closure would capture `self` before every stored property is
    /// initialized; the helper sidesteps that — the Task is assigned to
    /// `inFlightSubscription.task` *after* init has set all stored properties,
    /// and the helper's own `deinit` cancels it (so no main-actor state is
    /// touched from a nonisolated deinit).
    private let inFlightSubscription = InFlightSubscription()

    // MARK: Lists arriving while the sheet is open (plan 40)

    /// Hears the lists kept while the sheet is open; nothing while closed.
    private let arrivals = InFlightSubscription()
    /// Images whose list came since the rows last changed.
    @ObservationIgnored private var arrived: Set<String> = []
    @ObservationIgnored private var rowsDue: Task<Void, Never>?
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// The filters' names, merged as each list comes, out of sight: the
    /// filter pane is a `List` of thousands of rows, redrawn whole by any
    /// change, so `allPackages` changes once the lists stop coming.
    @ObservationIgnored private var packagesComing: AllPackages?
    /// How often a stream of lists changed the rows, and the filters: at
    /// most once a second, and once (tests read them).
    @ObservationIgnored private(set) var rowUpdates = 0
    @ObservationIgnored private(set) var filterUpdates = 0
    /// The rows change at most this often while lists come; the filters
    /// once they have stopped coming for `settleAfter`.
    nonisolated static let rowsEvery: Duration = .seconds(1)
    nonisolated static let settleAfter: Duration = .seconds(2)

    init(coordinator: ImageDiscoveryCoordinator) {
        self.coordinator = coordinator
        // Bind `inFlightProbeCount` to the coordinator's stream
        // for the model's entire lifetime. `[weak self]` so the
        // task self-terminates if the model is deallocated; the
        // stream's `.onTermination` callback cleans up the
        // coordinator-side continuation in that case.
        //
        // `.utility` priority: in-flight count changes are a
        // background-awareness signal (the magnifier badge), not a
        // latency-critical interaction. Running the subscription at
        // utility priority keeps a flurry of count mutations — which
        // can arrive rapidly when a batch of probes starts/finishes
        // — from competing with user-driven UI work on the main
        // actor. The brief hop to mutate `inFlightProbeCount` still
        // lands on the MainActor (the property is MainActor-isolated)
        // but is scheduled behind any pending higher-priority work.
        let stream = coordinator.inFlightCountChanges()
        // Assigned after every stored property is initialized, so capturing
        // `self` (weakly) here is legal. The helper's deinit cancels the Task
        // when the model is deallocated; the stream's `.onTermination` then
        // unregisters the coordinator-side continuation.
        inFlightSubscription.task = Task(priority: .utility) { [weak self] in
            for await count in stream {
                guard let self else { return }
                self.inFlightProbeCount = count
            }
        }
    }

    // MARK: - Open / close lifecycle

    /// Sheet just appeared: load the catalogue and hydrate row
    /// states from cache. **Does NOT auto-start discovery** — the
    /// user triggers each probe explicitly via the per-row Discover
    /// button. Auto-running was reverted because (a) it commits real
    /// Skaha resources without explicit consent, and (b) failures
    /// across the catalogue cluster up faster than the user can
    /// triage.
    func onAppear(catalogue images: [ParsedImage]) async {
        listenForArrivals()
        let attempt = catalogue.begin()
        allKnownImages = images
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
            await hydrateFromCacheOnly(attempt)
        } else {
            catalogue.finish(attempt, with: .success(Date()))
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
            recoveryNote = "Recovered \(n) manifest\(n == 1 ? "" : "s") that completed in the background after the prior attempt's polling deadline."
        }
    }

    /// Build `allKnownImages` purely from cached manifest ids when
    /// the live catalogue isn't available. Everything else (row
    /// states, allPackages) gets refreshed against the now-populated
    /// id list so the right pane mirrors what the cache knows.
    private func hydrateFromCacheOnly(_ attempt: Attempt) async {
        let cachedIDs = await coordinator.knownImages()
        guard !cachedIDs.isEmpty else {
            catalogue.finish(attempt, with: .failure(Problem(.offline, "The live image catalogue is unavailable.")))
            return
        }
        allKnownImages = cachedIDs.map {
            ImageParser.parse(RawImage(id: $0, types: []))
        }
        await refreshFromCache()
        catalogue.finish(attempt, with: .failure(Problem(.offline, "Live image catalogue unavailable — showing \(cachedIDs.count) image\(cachedIDs.count == 1 ? "" : "s") from local cache.", retry: false)))
    }

    /// Sheet about to dismiss. The coordinator's polling continues
    /// in the background — we just stop driving the UI.
    func onDisappear() {
        // Cancellation of the discovery stream happens automatically
        // when the wrapping Task is cancelled (caller in the View).
        arrivals.task?.cancel()
        arrivals.task = nil
    }

    /// While the sheet is open, the lists another device's probes made —
    /// a new device's first sync brings about three hundred — turn their
    /// rows to discovered as they come (plan 40).
    private func listenForArrivals() {
        guard arrivals.task == nil else { return }
        let stream = coordinator.manifestChanges()
        arrivals.task = Task(priority: .utility) { [weak self] in
            for await imageID in stream {
                guard let self else { return }
                self.arrivedList(imageID)
            }
        }
    }

    private func arrivedList(_ imageID: String) {
        arrived.insert(imageID)
        if rowsDue == nil {
            rowsDue = Task { [weak self] in
                try? await Task.sleep(for: Self.rowsEvery)
                await self?.showArrivedRows()
            }
        }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleAfter)
            guard !Task.isCancelled else { return }
            await self?.showArrivedPackages()
        }
    }

    /// One change to the rows for every list that came since the last.
    private func showArrivedRows() async {
        rowsDue = nil
        let ids = arrived
        arrived = []
        var rows = rowStates
        var packages = packagesComing ?? allPackages
        // A row for an image the sheet lists; every list's names for the
        // filters, as the cache gives them on opening.
        let listed = Set(allKnownImages.map(\.id))
        for id in ids {
            guard case .success(let manifest) = await coordinator.outcome(for: id) else { continue }
            if listed.contains(id) {
                rows[id] = .discovered(manifest)
                failureCategories.removeValue(forKey: id)
            }
            Self.merge(manifest, into: &packages)
        }
        packagesComing = packages
        if rows != rowStates {
            rowStates = rows
            rowUpdates += 1
        }
    }

    /// The filters, once the lists have stopped coming — when they gained names.
    private func showArrivedPackages() async {
        if !arrived.isEmpty { await showArrivedRows() }
        guard let packages = packagesComing else { return }
        packagesComing = nil
        if packages != allPackages {
            allPackages = packages
            filterUpdates += 1
        }
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
        guard !discovery.isWorking else { return }
        let attempt = discovery.begin()
        defer { discovery.finish(attempt, with: .success(Date())) }

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
        Self.merge(m, into: &allPackages)
    }

    /// A list's names among the filters'.
    static func merge(_ m: ImageManifest, into packages: inout AllPackages) {
        if m.osFamily != "unknown" {
            packages.osFamilies.insert(m.osFamily)
            if m.osVersion != "unknown" {
                packages.osVersionsByFamily[m.osFamily, default: []].insert(m.osVersion)
            }
        }
        for p in m.dpkgPackages   { packages.dpkg.insert(p.name) }
        for p in m.rpmPackages    { packages.rpm.insert(p.name) }
        for p in m.apkPackages    { packages.apk.insert(p.name) }
        for p in m.pythonPackages { packages.python.insert(p.name) }
        for p in m.rPackages      { packages.r.insert(p.name) }
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
            actions.fail(Problem(.other, "Rediscover \(imageID): \(err.displayMessage)"))
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

    /// Drop the cached failure for `imageID` and reset the row to
    /// never-discovered. Doesn't re-probe — the user explicitly
    /// chose to dismiss without retrying.
    func clearFailure(_ imageID: String) async {
        do {
            try await coordinator.invalidate(imageID: imageID)
            rowStates[imageID] = .neverDiscovered
            failureCategories.removeValue(forKey: imageID)
        } catch {
            actions.fail(Problem(.other, "Couldn't clear \(imageID): \(error.localizedDescription)"))
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
            actions.fail(Problem(.other, "Couldn't clear failures: \(error.localizedDescription)"))
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
        case .jobFailed:          return "Job failed"
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
        if elapsed < 30 { return String(localized: "just now") }
        if elapsed < 60 { return String(localized: "\(Int(elapsed))s ago") }
        if elapsed < 3_600 {
            let m = Int(elapsed / 60)
            return String(localized: "\(m)m ago")
        }
        if elapsed < 86_400 {
            let h = Int(elapsed / 3_600)
            return String(localized: "\(h)h ago")
        }
        if elapsed < 14 * 86_400 {
            let d = Int(elapsed / 86_400)
            return String(localized: "\(d)d ago")
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

/// Owns a single long-lived subscription `Task` and cancels it on `deinit`.
///
/// Extracted so `ImageDiscoveryModel` (an `@Observable @MainActor` type) can
/// hold its subscription as a plain `let` with no `nonisolated(unsafe)` escape
/// hatch: the model stores an `InFlightSubscription`, assigns its `task` once
/// during init (after all stored properties are set, so a `[weak self]`
/// capture is legal), and relies on this helper's own `deinit` to cancel —
/// which runs in a nonisolated context and touches no main-actor state. The
/// helper is created and mutated only from the model's MainActor init, so a
/// single-writer `@unchecked Sendable` is accurate.
private final class InFlightSubscription: @unchecked Sendable {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}
