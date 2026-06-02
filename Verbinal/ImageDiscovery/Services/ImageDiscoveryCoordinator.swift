// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
import VerbinalKit

// MARK: - Narrow protocol facades

/// Just the slice of `HeadlessService` the coordinator needs.
/// Allows mocking in tests without depending on the full
/// HeadlessService surface (which itself depends on NetworkClient
/// and the Skaha endpoints).
protocol HeadlessProbeLauncher: Sendable {
    func launchHeadlessJob(_ params: HeadlessLaunchParams) async throws -> [String]
    func getHeadlessJobs() async throws -> [HeadlessJob]
    func getLogs(id: String) async throws -> String
    func getEvents(id: String) async throws -> String
}

/// Just the VOSpace operations the coordinator needs:
/// upload (for the probe script), download (for the manifest), and
/// idempotent folder create (because VOSpace doesn't auto-create
/// parents on upload — `.verbinal/` has to exist BEFORE we PUT
/// `.verbinal/probe-<hash>.sh` or the server returns HTTP 404
/// "parent container not found").
protocol VOSpaceFileTransfer: Sendable {
    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws
    func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String)
    func createFolder(username: String, parentPath: String, folderName: String) async throws
}

// HeadlessService and VOSpaceBrowserService get these conformances
// in the AppState wiring file (Phase 3 / 4) — they already implement
// these methods, so the conformance is a one-liner there.

// MARK: - Coordinator

/// Orchestrates per-image discovery: upload probe.sh once → launch
/// probe job → poll until terminal → fetch manifest from VOSpace →
/// parse → store. Coalesces concurrent callers via `inFlight`. Runs
/// the actual probe as a `Task.detached` so caller cancellation
/// (UI dismissal) doesn't kill the probe other joiners depend on.
///
/// Concurrency contract:
///   * The actor serializes mutations to `inFlight` and
///     `probeScriptUploaded`.
///   * The detached probe task does its own polling outside the
///     actor (it makes async calls back via the protocol facades);
///     it returns a value the actor stores when it completes.
///   * Cleanup of `inFlight[imageID]` happens in a *separate* task
///     that awaits the detached task, so per-caller cancellation
///     never strands an in-flight entry.
actor ImageDiscoveryCoordinator {

    private static let logger = Logger(
        subsystem: "com.codebg.Verbinal",
        category: "ImageDiscovery.coordinator"
    )

    private let store: any ManifestStore
    private let headless: any HeadlessProbeLauncher
    private let vospace: any VOSpaceFileTransfer
    private let username: String

    /// Optional lookup so the coordinator can ask "what types does
    /// image X support?" at probe time. The answer drives strategy:
    /// types-include-headless → in-target probe (current path);
    /// otherwise → inspector probe (a known headless image
    /// introspects the target via static layer scan). Nil lookup
    /// or nil result falls back to in-target (matches the prior
    /// single-strategy world).
    private let imageTypesLookup: (@Sendable (String) async -> [String]?)?

    /// Optional builder for the `x-skaha-registry-auth` header. The
    /// closure reads the current Settings ▸ Image Discovery state
    /// (username + Keychain secret) and returns the
    /// `base64(username:secret)` value, or `nil` when credentials
    /// aren't configured. Probes pass the result through to
    /// `HeadlessLaunchParams.registryAuthHeader` so Skaha can pull
    /// from private namespaces. Nil closure ⇒ no header ⇒ matches
    /// the historic behaviour (works only for public images).
    private let registryAuthProvider: (@Sendable () async -> String?)?

    /// Optional resolver for the inspector-mode host image. When
    /// nil, falls back to `InspectorScript.resolvedInspectorImageID()`
    /// (UserDefaults override → builtin). Settings ▸ Image
    /// Discovery installs a closure reading the user-configured
    /// override so power users can swap in a custom inspector
    /// image without touching the Swift code.
    private let inspectorImageResolver: (@Sendable () async -> String)?

    /// Strategy choice per image — pure function of types.
    enum ProbeStrategy: Sendable, Equatable {
        case inTarget    // run probe.sh inside the target image
        case inspector   // launch a known-good headless image to inspect target
    }

    /// Foreground timeout for a single probe job. Default 10
    /// minutes — bumped from the prior 5 min after the
    /// 2026-05-21 observation that inspector-mode probes against
    /// multi-GB CANUCS images sit Pending up to 8 min while
    /// `syft registry:<target>` pulls every layer's manifest
    /// through our `x-skaha-registry-auth` header. Tests
    /// override much lower.
    private let probeJobTimeout: TimeInterval

    /// Background grace polling budget after the foreground
    /// `probeJobTimeout` elapses. Within this window, a
    /// detached task continues to check VOSpace for the
    /// manifest at a coarser interval — if the probe job runs
    /// past the foreground budget but writes its manifest
    /// while the grace task is still watching, the cache picks
    /// it up automatically. Default 10 min.
    private let graceJobTimeout: TimeInterval

    /// How often the grace task re-checks VOSpace for a late-
    /// landing manifest. Default 30s — coarse enough not to
    /// thrash, tight enough that the cache reflects success
    /// within a single user attention span.
    private let graceCheckInterval: TimeInterval

    /// How often to re-list jobs while polling.
    private let pollInterval: TimeInterval

    /// Bound for the AsyncStream batch fan-out.
    private let maxConcurrentProbes: Int

    /// Coalescing map: image id → in-flight discovery task.
    private var inFlight: [String: Task<ImageManifest, Error>] = [:]

    /// Live subscribers wanting `inFlight.count` changes. Each
    /// `inFlightCountChanges()` call registers under a fresh UUID
    /// and unregisters via `.onTermination` when the consumer
    /// cancels. Internal mutation sites (`inFlight[...] = task` and
    /// `clearInFlight`) call `broadcastInFlightChange()` after the
    /// mutation so every subscriber receives the new count. Yields
    /// only on actual change, not on every mutation that ended at
    /// the same value (cheap dedupe via `lastBroadcastCount`).
    private var inFlightContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var lastBroadcastCount: Int = 0

    /// Whether we've uploaded `probe-<scriptHash>.sh` to the user's
    /// VOSpace this session. Once true, subsequent probes skip the
    /// upload. Cleared by `setProbeScriptNotUploaded()` for tests.
    private var probeScriptUploaded: Bool = false

    /// Same as `probeScriptUploaded` but for the inspector path.
    /// Inspector script is independently versioned (different hash
    /// → different uploaded filename) so the two scripts can coexist
    /// in `.verbinal/` without overlap.
    private var inspectorScriptUploaded: Bool = false

    init(
        store: any ManifestStore,
        headless: any HeadlessProbeLauncher,
        vospace: any VOSpaceFileTransfer,
        username: String,
        probeJobTimeout: TimeInterval = 600,
        graceJobTimeout: TimeInterval = 600,
        graceCheckInterval: TimeInterval = 30,
        pollInterval: TimeInterval = 3,
        maxConcurrentProbes: Int = 5,
        imageTypesLookup: (@Sendable (String) async -> [String]?)? = nil,
        registryAuthProvider: (@Sendable () async -> String?)? = nil,
        inspectorImageResolver: (@Sendable () async -> String)? = nil
    ) {
        self.store = store
        self.headless = headless
        self.vospace = vospace
        self.username = username
        self.probeJobTimeout = probeJobTimeout
        self.graceJobTimeout = graceJobTimeout
        self.graceCheckInterval = graceCheckInterval
        self.pollInterval = pollInterval
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
        self.imageTypesLookup = imageTypesLookup
        self.registryAuthProvider = registryAuthProvider
        self.inspectorImageResolver = inspectorImageResolver
    }

    // MARK: - Cache pass-through

    func outcome(for imageID: String) async -> LastOutcome? {
        await store.outcome(for: imageID)
    }

    func knownImages() async -> [String] {
        await store.knownImages()
    }

    func allPackages() async -> AllPackages {
        await store.allPackages()
    }

    func search(_ query: PackageQuery) async -> [String] {
        await store.search(query)
    }

    func searchPartial(
        _ query: PackageQuery,
        minScore: Double,
        limit: Int
    ) async -> [PartialMatch] {
        await store.searchPartial(query, minScore: minScore, limit: limit)
    }

    /// Wipe every cached manifest and failure record. Surfaced via
    /// Settings ▸ "Clear discovery cache". Doesn't cancel any
    /// in-flight probe jobs — they'll repopulate the cache when
    /// they complete.
    func clearCache() async throws {
        try await store.clear()
    }

    /// Drop a single image's cached outcome (success OR failure).
    /// The discovery sheet calls this from the per-row "Dismiss
    /// error" button to take a failed row back to never-discovered
    /// state without launching a fresh probe.
    func invalidate(imageID: String) async throws {
        try await store.invalidate(imageID: imageID)
    }

    /// Drop every cached *failure* — leave successful manifests
    /// intact. Surfaced as the "Clear all errors" button in the
    /// sheet header when failed rows exist.
    func clearFailures() async throws {
        for id in await store.knownImages() {
            if case .failure = await store.outcome(for: id) {
                try await store.invalidate(imageID: id)
            }
        }
    }

    /// Number of cached records — used by Settings to render the
    /// "Clear cache (N entries)" label.
    func cacheCount() async -> Int {
        await store.count()
    }

    // MARK: - Single-image discovery

    /// Discover packages for one image. Returns the cached manifest
    /// if one exists and `force` is false; otherwise launches a
    /// probe job, polls until terminal, fetches and parses the
    /// manifest, persists it, returns it.
    func discover(_ imageID: String, force: Bool = false) async throws -> ImageManifest {
        // Cache hit short-circuit.
        if !force, case .success(let manifest) = await store.outcome(for: imageID) {
            return manifest
        }

        // Already in flight? Coalesce with the existing task.
        if let existing = inFlight[imageID] {
            return try await existing.value
        }

        // Launch the probe in a detached task so caller cancellation
        // doesn't kill it. Other joiners wait on the same Task.
        let task = Task.detached { [weak self] () async throws -> ImageManifest in
            guard let self else { throw ImageDiscoveryError.cancelled }
            return try await self.runDiscovery(for: imageID, force: force)
        }
        inFlight[imageID] = task
        broadcastInFlightChange()

        // Schedule cleanup separately so per-caller cancellation
        // doesn't strand the inFlight entry.
        Task { [weak self] in
            _ = try? await task.value
            await self?.clearInFlight(imageID)
        }

        return try await task.value
    }

    /// Force-rediscover an image (Phase 5 wires this to the per-row
    /// "Rediscover" button). Drops any cached entry first, then runs
    /// the same path as `discover(force: true)`.
    func rediscover(_ imageID: String) async throws -> ImageManifest {
        try await store.invalidate(imageID: imageID)
        return try await discover(imageID, force: true)
    }

    // MARK: - Batch streaming

    /// Discover a list of images, yielding events as each lands.
    /// Cache hits yield `.completed` instantly; misses run through
    /// the bounded-concurrency probe pipeline. Returns when every
    /// image has either completed or failed; the stream finishes
    /// itself.
    nonisolated func discoverAll(_ ids: [String]) -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runBatch(ids: ids, continuation: continuation)
                continuation.finish()
            }
        }
    }

    private func runBatch(
        ids: [String],
        continuation: AsyncStream<DiscoveryEvent>.Continuation
    ) async {
        guard !ids.isEmpty else { return }

        // Snapshot the cap because the actor's value may change later
        // (rare, but defensive).
        let cap = maxConcurrentProbes

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            // Prime the pool.
            let initial = min(cap, ids.count)
            for i in 0..<initial {
                let id = ids[i]
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.processOne(id, continuation: continuation)
                }
            }
            nextIndex = initial

            // Drain & refill: each completed task starts the next.
            while await group.next() != nil {
                if nextIndex < ids.count {
                    let id = ids[nextIndex]
                    nextIndex += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.processOne(id, continuation: continuation)
                    }
                }
            }
        }
    }

    private func processOne(
        _ id: String,
        continuation: AsyncStream<DiscoveryEvent>.Continuation
    ) async {
        // Cache hit: yield .completed immediately, no .started event.
        if case .success(let manifest) = await store.outcome(for: id) {
            continuation.yield(.completed(imageID: id, manifest: manifest))
            return
        }

        continuation.yield(.started(imageID: id))
        do {
            let manifest = try await discover(id, force: false)
            continuation.yield(.completed(imageID: id, manifest: manifest))
        } catch let err as ImageDiscoveryError {
            continuation.yield(.failed(imageID: id, error: err))
        } catch {
            continuation.yield(.failed(imageID: id,
                                       error: .unknown(message: error.localizedDescription)))
        }
    }

    // MARK: - Discovery pipeline

    private func runDiscovery(for imageID: String, force: Bool = false) async throws -> ImageManifest {
        let strategy = await strategy(for: imageID)

        // Upload whichever script(s) the strategy requires. Both
        // share the same `.verbinal/` parent dir; ensure-* is
        // idempotent so this is cheap on repeat calls.
        do {
            switch strategy {
            case .inTarget:  try await ensureProbeScript()
            case .inspector: try await ensureInspectorScript()
            }
        } catch {
            try? await persistFailure(
                imageID: imageID,
                error: .jobSubmitFailed(message: "script upload: \(error.localizedDescription)"),
                jobID: nil
            )
            throw ImageDiscoveryError.jobSubmitFailed(message: error.localizedDescription)
        }

        // Recovery short-circuit: a previous probe (either strategy)
        // may have completed and written the manifest to VOSpace,
        // but our poll loop timed out before catching its terminal
        // state. The manifest is sitting at the expected path —
        // strategy-agnostic, so the recovery just works for both.
        if !force, let manifest = try? await fetchManifestIfPresent(for: imageID) {
            try await store.setManifest(manifest)
            return manifest
        }

        let jobID: String
        do {
            switch strategy {
            case .inTarget:
                jobID = try await launchProbeJobWithRetry(for: imageID)
            case .inspector:
                jobID = try await launchInspectorJobWithRetry(for: imageID)
            }
        } catch let HeadlessLaunchError.partialReplicaFailure(_, _, msg) {
            let err = ImageDiscoveryError.jobSubmitFailed(message: msg)
            try? await persistFailure(imageID: imageID, error: err, jobID: nil)
            throw err
        } catch let typed as ImageDiscoveryError {
            // The retry helper already produces `ImageDiscoveryError`
            // for known patterns (e.g. the friendly Skaha-refused
            // message after both attempts hit the race). Pass it
            // through untouched — wrapping it again would erase
            // the typed message and surface Cocoa's "error 0"
            // fallback in its place.
            try? await persistFailure(imageID: imageID, error: typed, jobID: nil)
            throw typed
        } catch {
            let err = ImageDiscoveryError.jobSubmitFailed(message: error.localizedDescription)
            try? await persistFailure(imageID: imageID, error: err, jobID: nil)
            throw err
        }

        do {
            try await pollUntilTerminal(jobID: jobID)
        } catch {
            // Poll-timeout fallthrough: the probe job may have
            // *completed* and written the manifest after our last
            // poll tick. Try a fetch before giving up — saves the
            // user from re-running a probe that already produced
            // its output.
            if let manifest = try? await fetchManifestIfPresent(for: imageID) {
                try await store.setManifest(manifest)
                return manifest
            }
            let err: ImageDiscoveryError
            if let typed = error as? ImageDiscoveryError {
                err = typed
            } else {
                err = .unknown(message: error.localizedDescription)
            }
            try? await persistFailure(imageID: imageID, error: err, jobID: jobID)
            // 2026-05-21: when the foreground budget runs out
            // but the probe is still alive on Skaha, the
            // manifest commonly lands at VOSpace 1–3 minutes
            // later. Spawn a detached grace task that polls the
            // VOSpace path at `graceCheckInterval` for
            // `graceJobTimeout`; if it finds the manifest, the
            // store updates and the next sheet open (or
            // recoverFromVOSpaceIfPresent call) picks up the
            // success silently. Only run this for jobTimedOut
            // — other failure modes (submit failed, parse
            // failed) won't change with more waiting.
            if case .jobTimedOut = err {
                spawnGracePoll(for: imageID)
            }
            throw err
        }

        let data: Data
        do {
            data = try await fetchManifestData(for: imageID)
        } catch {
            let err = ImageDiscoveryError.manifestFetchFailed(message: error.localizedDescription)
            try? await persistFailure(imageID: imageID, error: err, jobID: jobID)
            throw err
        }

        let manifest: ImageManifest
        do {
            manifest = try ManifestParser.parse(data)
        } catch let pe as ManifestParser.ParseError {
            let detail: String
            switch pe {
            case .empty: detail = "empty"
            case .malformed(let s): detail = s
            case .unknownSchema(let v): detail = "unknownSchema(\(v))"
            }
            let err = ImageDiscoveryError.manifestParseFailed(detail: detail)
            try? await persistFailure(imageID: imageID, error: err, jobID: jobID)
            throw err
        } catch {
            let err = ImageDiscoveryError.manifestParseFailed(detail: error.localizedDescription)
            try? await persistFailure(imageID: imageID, error: err, jobID: jobID)
            throw err
        }

        try await store.setManifest(manifest)
        return manifest
    }

    /// Try to read the manifest from VOSpace and parse it. Returns
    /// `nil` (not throws) when the file is missing OR can't be
    /// parsed — both are valid "no usable manifest yet" states the
    /// caller wants to treat as recoverable. A caller fetching
    /// explicitly after a successful probe goes through
    /// `fetchManifestData` instead and gets typed errors.
    ///
    /// **Stub-manifest guard**: prior versions of the inspector
    /// script left structured-but-empty manifests in VOSpace when
    /// syft / python / pipeline plumbing failed (e.g. `probeNotes:
    /// "syft output unreadable"`, all package arrays empty). Those
    /// JSON blobs parse cleanly but carry no usable data — caching
    /// them would mean every Discover click silently re-uses the
    /// failure. We detect that shape and report cache-miss, which
    /// forces a fresh probe with the current (fixed) script.
    private func fetchManifestIfPresent(for imageID: String) async throws -> ImageManifest? {
        let data: Data
        do {
            data = try await fetchManifestData(for: imageID)
        } catch {
            return nil
        }
        let manifest: ImageManifest
        do {
            manifest = try ManifestParser.parse(data)
        } catch {
            return nil
        }
        // Sanity: the manifest at the expected path must be FOR
        // this image. Defends against probe-collision where two
        // launches with mismatched IMAGE_ID env vars wrote to the
        // same path (pathological, but cheap to verify).
        guard manifest.imageID == imageID else { return nil }
        if Self.isStubManifest(manifest) {
            Self.logger.notice("ignoring stub manifest in VOSpace for \(imageID, privacy: .public); will re-probe")
            return nil
        }
        return manifest
    }

    /// A "stub" manifest is one a failed probe wrote as a
    /// placeholder: no packages of any kind, and a `probeNotes`
    /// field describing the failure. Real successful probes always
    /// have *something* (even Alpine's minimal image returns a
    /// dozen apk entries) and don't set `probeNotes`. Used by
    /// `fetchManifestIfPresent` to refuse to cache failure
    /// placeholders, and intended to be cheap (no I/O) so the
    /// recovery path stays a single-VOSpace-read in the happy case.
    static func isStubManifest(_ m: ImageManifest) -> Bool {
        let hasPackages = !(m.dpkgPackages.isEmpty
                            && m.rpmPackages.isEmpty
                            && m.apkPackages.isEmpty
                            && m.pythonPackages.isEmpty
                            && m.rPackages.isEmpty
                            && m.condaEnvs.isEmpty)
        if hasPackages { return false }
        // Empty-everything is the stub shape; require a probeNotes
        // tag too so a hypothetical legitimate "scratch" image with
        // truly zero packages doesn't get mistaken for a stub.
        return (m.probeNotes ?? "").isEmpty == false
    }

    /// Fetch the container stdout/stderr for a probe's Skaha session.
    /// Used by the discovery sheet's "View logs" action on a failed
    /// row so the user can read the underlying error.
    func fetchLogs(jobID: String) async throws -> String {
        try await headless.getLogs(id: jobID)
    }

    /// Fetch the Kubernetes-level events for a probe's Skaha session
    /// (scheduling, image pulls, OOM kills). Often the only signal
    /// for a job stuck in Pending or one that ImagePullBackOff'd.
    func fetchEvents(jobID: String) async throws -> String {
        try await headless.getEvents(id: jobID)
    }

    /// Build a Skaha session-name that's safe for K8s DNS-1123
    /// label rules (≤63 chars, lowercase alphanumerics + hyphens,
    /// no leading/trailing hyphen, no consecutive hyphens).
    ///
    /// Old builder produced names like
    /// `verbinal-inspect-images-canfar-net-cadc-carta-psrecord-5--abcd1234`
    /// (66 chars, double hyphen mid-name) — the length tripped K8s
    /// admission webhooks (label-value cap is 63), and the
    /// trailing chop landed inside `5.1.0` leaving a stray `5-` that
    /// Skaha's Java regex parser is known to choke on. Both fits
    /// the "K8s race after submit" pattern we kept seeing.
    ///
    /// The new builder reserves the prefix + UUID up front, slices
    /// the image-derived middle to whatever's left, then collapses
    /// `_`/`.`/space → `-`, drops consecutive hyphens, and trims
    /// edge hyphens. Worst case: `vp-<54chars>-<8uuid>` = 64 — but
    /// the slice already caps the middle at 52, so we're at most 63.
    static func makeJobName(prefix: String, imageID: String) -> String {
        let uuid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        // K8s label cap (63) minus prefix, separators, uuid.
        let budget = 63 - prefix.count - 1 - uuid.count - 1   // "<prefix>-<middle>-<uuid>"
        let safe = ImageManifest.sanitize(imageID: imageID).lowercased()
        var middle = String(safe.prefix(max(0, budget)))
        // Replace any non-DNS-1123 char with hyphen, then collapse
        // runs of hyphens, then trim leading/trailing hyphens.
        middle = middle.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" { return ch }
            return "-"
        }.reduce(into: "") { acc, ch in
            if ch == "-" && acc.last == "-" { return }
            acc.append(ch)
        }
        while middle.hasPrefix("-") { middle.removeFirst() }
        while middle.hasSuffix("-") { middle.removeLast() }
        // If trimming somehow emptied the middle (degenerate input),
        // fall back to the uuid alone so we still produce a valid name.
        if middle.isEmpty { return "\(prefix)-\(uuid)" }
        return "\(prefix)-\(middle)-\(uuid)"
    }

    /// Pure decision: which strategy applies to this image's types.
    /// Headless-capable → in-target probe (probe.sh runs inside the
    /// target image itself). Anything else → inspector (probe a known-
    /// good public image and have syft introspect the target via
    /// registry metadata).
    ///
    /// **Unknown types fall back to `.inspector`**, not `.inTarget`.
    /// 2026-05-19 finding: when `imageTypesLookup` returns nil
    /// (catalogue miss, fetch failure, or the user is probing an
    /// image they discovered out-of-band), the prior `.inTarget`
    /// fallback asked Skaha to pull the unknown target as the probe
    /// host — which fails immediately with HTTP 400 "No
    /// authentication provided for unknown or private image" when
    /// the target lives in a private project namespace (CANUCS, any
    /// per-project images.canfar.net path, etc.). The inspector path
    /// is strictly safer for unknown images because:
    ///   * Skaha only pulls the public `terminal:1.1.2` host, which
    ///     never requires registry auth.
    ///   * If the target itself is unreachable from inside the
    ///     container, syft surfaces a structured `probeNotes`
    ///     manifest (the inspector script catches non-zero rc and
    ///     writes a minimal one) — failure becomes cached state, not
    ///     a recurring 400.
    /// The opposite default penalised every non-public namespace
    /// the catalogue didn't enumerate.
    static func strategy(forTypes types: [String]?) -> ProbeStrategy {
        guard let types else { return .inspector }   // unknown: safe default
        return types.contains("headless") ? .inTarget : .inspector
    }

    /// Resolves strategy by consulting the injected types lookup;
    /// inFlight + recovery paths use this so the choice is consistent
    /// across retries.
    private func strategy(for imageID: String) async -> ProbeStrategy {
        let types = await imageTypesLookup?(imageID)
        return Self.strategy(forTypes: types)
    }

    private func ensureProbeScript() async throws {
        if probeScriptUploaded { return }

        // VOSpace doesn't auto-create parent folders on PUT.
        // Idempotent mkdir — already-exists errors are swallowed
        // because the only way to *know* the folder exists is to
        // ask, which costs a round-trip we'd otherwise repeat
        // every session. The probe script's internal `mkdir -p`
        // handles `.verbinal/manifests` from inside the container,
        // but the script upload itself happens FROM the Mac and
        // needs `.verbinal/` to be there beforehand.
        try? await vospace.createFolder(
            username: username,
            parentPath: "",
            folderName: ProbeScript.homeSubdirectory
        )

        // Write the embedded script body to a tempfile.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbinal-probe-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let local = tempDir.appendingPathComponent(ProbeScript.uploadFilename)
        try ProbeScript.body.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remote = "\(ProbeScript.homeSubdirectory)/\(ProbeScript.uploadFilename)"
        try await vospace.uploadFile(username: username, remotePath: remote, fileURL: local)

        probeScriptUploaded = true
        Self.logger.info("uploaded probe script to \(remote, privacy: .public)")
    }

    /// Sister of `ensureProbeScript` for the inspector path.
    /// Independent flag because the two scripts have different hashes
    /// and live as different files; a session might use both depending
    /// on which targets the user inspects.
    private func ensureInspectorScript() async throws {
        if inspectorScriptUploaded { return }

        try? await vospace.createFolder(
            username: username,
            parentPath: "",
            folderName: ProbeScript.homeSubdirectory   // shared parent dir
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbinal-inspector-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let local = tempDir.appendingPathComponent(InspectorScript.uploadFilename)
        try InspectorScript.body.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remote = "\(ProbeScript.homeSubdirectory)/\(InspectorScript.uploadFilename)"
        try await vospace.uploadFile(username: username, remotePath: remote, fileURL: local)

        inspectorScriptUploaded = true
        Self.logger.info("uploaded inspector script to \(remote, privacy: .public)")
    }

    /// Submit the probe job, retrying once on Skaha's known
    /// eventual-consistency race where the POST succeeds in
    /// creating the K8s `jobs.batch` resource but Skaha's
    /// immediate follow-up GET returns `404 jobs.batch ... not
    /// found` (surfaced to the caller as HTTP 500). The race is
    /// rare on the typical case but reproducible on small/fast-
    /// scheduling images. Single retry after 2.5s lets the K8s
    /// API server's read replica catch up.
    ///
    /// Wrapped in the launch-slot semaphore so a flurry of probe
    /// requests doesn't burst against Skaha's per-namespace rate
    /// limit (which it reports as the same misleading
    /// jobs.batch-not-found error).
    private func launchProbeJobWithRetry(for imageID: String) async throws -> String {
        await acquireLaunchSlot()
        defer { releaseLaunchSlot() }
        return try await retryingOnSkahaRace(label: "probe", imageID: imageID) {
            try await self.launchProbeJob(for: imageID)
        }
    }

    /// Same retry envelope around the inspector launch path. The
    /// race is at submission time (Skaha + K8s API server), not
    /// strategy-specific — both probe and inspector launches go
    /// through the same Skaha endpoint and hit the same race.
    /// Same launch-slot semaphore as the in-target path.
    private func launchInspectorJobWithRetry(for targetImageID: String) async throws -> String {
        await acquireLaunchSlot()
        defer { releaseLaunchSlot() }
        return try await retryingOnSkahaRace(label: "inspector", imageID: targetImageID) {
            try await self.launchInspectorJob(for: targetImageID)
        }
    }

    /// Backoff schedule for the K8s `jobs.batch not found` race.
    /// Each entry is a delay (seconds) BEFORE the next attempt.
    /// Total wall-clock budget = sum of these. Field-tuned against
    /// observed Skaha informer-cache lag: a single 2.5s retry
    /// failed three times in 22 minutes for the same image, so
    /// the schedule was widened to absorb up to ~17s of lag.
    private static let skahaRaceBackoffsSec: [UInt64] = [3, 7, 15]

    /// Single shared retry harness used by both strategies. Keeps
    /// the race detection + backoff in one place so future
    /// adjustments only need editing here and `skahaRaceBackoffsSec`.
    ///
    /// On retry exhaustion: rewrap as `.jobSubmitFailed(message:)`
    /// with a diagnosis that reflects what Skaha actually does in
    /// this state — its REST handler created the K8s Job, then the
    /// immediate follow-up GET 404'd. That's an informer-cache lag
    /// or eager garbage-collection on Skaha's side, not a quota
    /// issue. The raw HTTP body is appended verbatim so the user
    /// can copy + paste into a CADC ticket.
    private func retryingOnSkahaRace<T: Sendable>(
        label: String,
        imageID: String,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        for (attempt, delay) in Self.skahaRaceBackoffsSec.enumerated() {
            do {
                return try await work()
            } catch {
                guard Self.isSkahaJobNotFoundRace(error) else { throw error }
                Self.logger.notice("\(label, privacy: .public) submit hit jobs.batch not-found race for \(imageID, privacy: .public) (attempt \(attempt + 1)); retrying after \(delay)s")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        // Final attempt after the last backoff. Either it succeeds
        // (returns), throws a non-race error (rethrows verbatim
        // because we don't catch it here), or throws the race
        // error one last time (caught below and rewrapped with the
        // friendly diagnosis message). All three exits are handled
        // — there is no falling-off-the-end case.
        do {
            return try await work()
        } catch let lastError where Self.isSkahaJobNotFoundRace(lastError) {
            let rawSkaha = lastError.localizedDescription
            let attempts = Self.skahaRaceBackoffsSec.count + 1
            Self.logger.error("\(label, privacy: .public) submit retry exhausted for \(imageID, privacy: .public) after \(attempts) attempts: \(rawSkaha, privacy: .public)")
            throw ImageDiscoveryError.jobSubmitFailed(
                message: "Skaha couldn't see the \(label) job it just created (\(attempts) attempts over ~\(Self.skahaRaceBackoffsSec.reduce(0, +))s). This is a Skaha-side K8s informer-cache lag or eager garbage-collection — not a quota issue. The audit-id in the response headers below ties to a CADC server log; copy this whole message into a ticket. Skaha said: \(rawSkaha)"
            )
        }
    }

    // MARK: - Concurrency throttle

    /// Hard cap on how many launch operations can be in flight at
    /// once across the *entire* coordinator. Prevents bursty user
    /// behaviour (rapid-fire Inspect clicks across many rows) from
    /// tripping Skaha's per-namespace rate limit, which Skaha
    /// reports back as the misleading "jobs.batch not found"
    /// error pattern.
    ///
    /// Modeled as a counting semaphore implemented inside the
    /// actor — each launch acquires before its work, releases
    /// when the launch returns (success OR failure). Bypassed for
    /// the post-launch poll loop because polling doesn't pressure
    /// Skaha's create path.
    private static let maxConcurrentLaunches: Int = 2
    private var inFlightLaunches: Int = 0
    private var launchWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireLaunchSlot() async {
        if inFlightLaunches < Self.maxConcurrentLaunches {
            inFlightLaunches += 1
            return
        }
        await withCheckedContinuation { continuation in
            launchWaiters.append(continuation)
        }
        // Resumed by `releaseLaunchSlot` which has already
        // decremented its own count and incremented ours.
        inFlightLaunches += 1
    }

    private func releaseLaunchSlot() {
        inFlightLaunches -= 1
        if let next = launchWaiters.first {
            launchWaiters.removeFirst()
            next.resume()
        }
    }

    /// Pattern-match the very specific error body Skaha returns
    /// during the race. Other HTTP 500s (real backend faults,
    /// quota exceeded, etc.) shouldn't trigger a retry.
    static func isSkahaJobNotFoundRace(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("jobs.batch") && msg.contains("not found")
    }

    /// Inspector-mode launch. The container image is a *known-good
    /// headless image* (default `terminal:1.1.2`, override via
    /// UserDefaults `InspectorScript.inspectorImageDefaultsKey`),
    /// the cmd is `bash` + the inspector script's absolute path, and
    /// the target image being probed is passed via `TARGET_IMAGE`
    /// env var. The inspector script runs syft against the registry
    /// URL of the target and writes a manifest at the same path the
    /// in-target probe writes — coordinator's recovery + cache
    /// layers don't care which strategy produced the file.
    private func launchInspectorJob(for targetImageID: String) async throws -> String {
        let jobName = Self.makeJobName(prefix: "vi", imageID: targetImageID)

        let scriptPath = "/arc/home/\(username)/\(ProbeScript.homeSubdirectory)/\(InspectorScript.uploadFilename)"
        // Inspector image: prefer the user-configured override from
        // Settings ▸ Image Discovery (lets the user point at a
        // custom image they built per docs/inspector-image.md);
        // fall back to the UserDefaults / builtin chain. Reading
        // the resolver on every launch — not caching — so a
        // Settings change takes effect on the next probe without
        // restarting the app.
        let inspectorImage: String
        if let resolver = inspectorImageResolver {
            inspectorImage = await resolver()
        } else {
            inspectorImage = InspectorScript.resolvedInspectorImageID()
        }
        let auth = await registryAuthProvider?()
        var params = HeadlessLaunchParams(
            name: jobName,
            image: inspectorImage,           // known-good headless host
            cmd: "bash",
            args: scriptPath,
            env: [("TARGET_IMAGE", targetImageID)],
            // 1c/1g/0gpu — the smallest schedulable shape on the
            // shared CANFAR cluster. The earlier `ram: 4` ask was
            // theoretically nicer for syft headroom, but 2026-05-19
            // observation: 4 GB inspector jobs sit Pending 15+ min
            // under cluster pressure while 1 GB ones place in <60s.
            // syft can OOM on truly huge target images, but that's
            // a structured failure (`probeNotes: "syft failed: out
            // of memory"`) the user can react to — far better than
            // an indefinite pending queue.
            cores: 1,
            ram: 1,
            gpus: 0,
            replicas: 1
        )
        params.registryAuthHeader = auth
        let ids = try await headless.launchHeadlessJob(params)
        guard let first = ids.first else {
            throw ImageDiscoveryError.jobSubmitFailed(message: "Skaha returned no job id")
        }
        return first
    }

    private func launchProbeJob(for imageID: String) async throws -> String {
        let jobName = Self.makeJobName(prefix: "vp", imageID: imageID)

        // Skaha hands `cmd` to the OCI runtime as the binary name
        // verbatim — no shell parsing. Joining "bash" + path with a
        // space ("bash /arc/.../probe.sh") makes the runtime look for
        // a binary literally named "bash /arc/.../probe.sh" (space
        // included) and fail with `stat: no such file or directory`.
        // Split: cmd = the binary, args = the path. Skaha tokenises
        // args by whitespace before passing to OCI; a single
        // space-free path becomes one argv[1] cleanly.
        //
        // Also: cmd must contain no `$` because Skaha runs cmd
        // through a Java regex replacer that treats `$X` as a
        // backreference (the previous `$HOME` bug). "bash" passes;
        // anything else with `$` would re-trigger HTTP 400.
        let scriptPath = "/arc/home/\(username)/\(ProbeScript.homeSubdirectory)/\(ProbeScript.uploadFilename)"
        let auth = await registryAuthProvider?()
        var params = HeadlessLaunchParams(
            name: jobName,
            image: imageID,
            cmd: "bash",
            args: scriptPath,
            env: [("IMAGE_ID", imageID)],
            // 1c/1g/0gpu — same rationale as the inspector path.
            // Smallest schedulable shape; the probe script's bash
            // + python3 footprint is well under 1 GB. Anything
            // bigger sits Pending under cluster pressure (observed
            // 2026-05-19) and the user perceives the discovery
            // feature as broken even when the script itself is
            // correct.
            cores: 1,
            ram: 1,
            gpus: 0,
            replicas: 1
        )
        params.registryAuthHeader = auth
        let ids = try await headless.launchHeadlessJob(params)
        guard let first = ids.first else {
            throw ImageDiscoveryError.jobSubmitFailed(message: "Skaha returned no job id")
        }
        return first
    }

    private func pollUntilTerminal(jobID: String) async throws {
        let deadline = Date().addingTimeInterval(probeJobTimeout)
        while Date() < deadline {
            let jobs: [HeadlessJob]
            do {
                jobs = try await headless.getHeadlessJobs()
            } catch {
                throw ImageDiscoveryError.unknown(message: "poll: \(error.localizedDescription)")
            }
            guard let job = jobs.first(where: { $0.id == jobID }) else {
                // Job dropped from listing — Skaha retains terminated
                // jobs for a window, so this likely means it completed
                // and was reaped. Treat as success and let the manifest
                // fetch validate.
                return
            }
            if job.isTerminal {
                if job.isFailed {
                    throw ImageDiscoveryError.unknown(message: "job ended in failed state: \(job.status)")
                }
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw ImageDiscoveryError.jobTimedOut
    }

    private func fetchManifestData(for imageID: String) async throws -> Data {
        let safe = ImageManifest.sanitize(imageID: imageID)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        let (tempURL, _) = try await vospace.downloadFile(username: username, path: path)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try Data(contentsOf: tempURL)
    }

    private func persistFailure(
        imageID: String,
        error: ImageDiscoveryError,
        jobID: String?
    ) async throws {
        try await store.setFailure(
            imageID: imageID,
            category: error.cacheCategory,
            message: error.displayMessage,
            attemptedAt: Date(),
            jobID: jobID
        )
    }

    // MARK: - Grace polling for late-landing manifests

    /// Spawn a detached task that polls VOSpace every
    /// `graceCheckInterval` seconds for the manifest at the
    /// expected path, for up to `graceJobTimeout` seconds. If
    /// the probe completes after the foreground deadline but
    /// before this grace deadline, the manifest gets recovered
    /// into the cache silently and the next user interaction
    /// (sheet reopen or explicit retry) sees it as a success.
    ///
    /// Self-terminates on:
    ///   * manifest found → updates cache, exits
    ///   * grace deadline elapsed → exits
    ///   * coordinator deallocated → exits via weak-self guard
    ///
    /// Runs on a detached executor (not the actor's) so the
    /// `Task.sleep` doesn't block other actor work. Calls back
    /// into the actor via `await self.fetchManifestIfPresent`
    /// for each check, which hops to the actor's executor for
    /// the brief VOSpace read.
    private func spawnGracePoll(for imageID: String) {
        let deadline = Date().addingTimeInterval(graceJobTimeout)
        let interval = graceCheckInterval
        Task.detached { [weak self] in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                if let manifest = try? await self.fetchManifestIfPresent(for: imageID) {
                    try? await self.store.setManifest(manifest)
                    await self.logGraceRecovery(imageID: imageID)
                    return
                }
            }
        }
    }

    private func logGraceRecovery(imageID: String) {
        Self.logger.notice("grace-poll recovered manifest for \(imageID, privacy: .public) after foreground timeout")
    }

    /// Public re-check of VOSpace for a previously-attempted
    /// image. Used by the discovery sheet on reopen to catch
    /// manifests that landed during the grace-poll window OR
    /// the gap between app launches. **Does not launch a new
    /// probe** — if VOSpace has nothing for this id, the
    /// existing failure outcome stays in place. Returns the
    /// manifest when found (and updates the local cache as a
    /// side effect); returns nil otherwise.
    func recoverFromVOSpaceIfPresent(imageID: String) async -> ImageManifest? {
        guard let manifest = try? await fetchManifestIfPresent(for: imageID) else {
            return nil
        }
        try? await store.setManifest(manifest)
        return manifest
    }

    // MARK: - Internal state hooks (for tests + cleanup)

    private func clearInFlight(_ imageID: String) {
        inFlight[imageID] = nil
        broadcastInFlightChange()
    }

    // MARK: - In-flight count surface (for background-jobs UX)

    /// Current count of probes the coordinator has in flight. Use
    /// `inFlightCountChanges()` for live updates instead of polling
    /// this — the stream wakes UI on every actual change without a
    /// timer.
    func inFlightCount() -> Int { inFlight.count }

    /// Sorted snapshot of image ids currently being probed.
    /// Powers tooltip / hover-detail UI ("3 probes running:
    /// foo:1, bar:2, baz:3"). Sorted for stable rendering across
    /// successive snapshots.
    func inFlightImageIDs() -> [String] { inFlight.keys.sorted() }

    /// Live `inFlight.count` stream. Yields the initial value
    /// immediately on subscribe so the UI can render a current
    /// badge without a first-poll race; subsequent yields only on
    /// actual count changes. The stream closes when the consumer
    /// stops iterating (`.onTermination` fires; coordinator
    /// drops the continuation).
    ///
    /// 2026-05-19 addition: the Discovery sheet "Close" button
    /// keeps probes running in the background. The badge bound to
    /// this stream gives the user continuous awareness from outside
    /// the sheet — they don't need to reopen to know whether a
    /// probe is still in progress.
    nonisolated func inFlightCountChanges() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let id = UUID()
            Task { [weak self] in
                await self?.registerInFlightContinuation(id, continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unregisterInFlightContinuation(id) }
            }
        }
    }

    private func registerInFlightContinuation(
        _ id: UUID,
        _ continuation: AsyncStream<Int>.Continuation
    ) {
        inFlightContinuations[id] = continuation
        // Initial value so the subscriber sees the current state
        // without waiting for the next mutation. lastBroadcastCount
        // is *not* updated here — the next real mutation will
        // re-broadcast if the value actually changed.
        continuation.yield(inFlight.count)
    }

    private func unregisterInFlightContinuation(_ id: UUID) {
        if let cont = inFlightContinuations.removeValue(forKey: id) {
            cont.finish()
        }
    }

    /// Yield the new count to every subscriber, but only when it
    /// actually changed since the last broadcast. Two consecutive
    /// `inFlight[x] = task` / `clearInFlight(x)` round-trips that
    /// land on the same count value (e.g. one launches, one
    /// finishes simultaneously) collapse into a single yield —
    /// agents subscribing don't see spurious churn.
    private func broadcastInFlightChange() {
        let count = inFlight.count
        guard count != lastBroadcastCount else { return }
        lastBroadcastCount = count
        for cont in inFlightContinuations.values {
            cont.yield(count)
        }
    }

    /// Test hook: pretend we haven't uploaded the probe script yet,
    /// so the next `discover` re-runs the upload path.
    func setProbeScriptNotUploaded() {
        probeScriptUploaded = false
    }

    /// Test hook: number of live `inFlightCountChanges()` subscribers
    /// currently registered. Lets a test assert that a subscriber's
    /// continuation is unregistered (count returns to zero) after the
    /// consumer's stream terminates — e.g. when the subscribing model
    /// is deallocated and its subscription Task ends, the stream's
    /// `.onTermination` should drop the coordinator-side continuation.
    func inFlightSubscriberCount() -> Int { inFlightContinuations.count }
}
