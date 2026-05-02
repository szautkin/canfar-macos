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

    /// Strategy choice per image — pure function of types.
    enum ProbeStrategy: Sendable, Equatable {
        case inTarget    // run probe.sh inside the target image
        case inspector   // launch a known-good headless image to inspect target
    }

    /// Hard timeout for a single probe job. Default 5 minutes; tests
    /// override much lower.
    private let probeJobTimeout: TimeInterval

    /// How often to re-list jobs while polling.
    private let pollInterval: TimeInterval

    /// Bound for the AsyncStream batch fan-out.
    private let maxConcurrentProbes: Int

    /// Coalescing map: image id → in-flight discovery task.
    private var inFlight: [String: Task<ImageManifest, Error>] = [:]

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
        probeJobTimeout: TimeInterval = 300,
        pollInterval: TimeInterval = 3,
        maxConcurrentProbes: Int = 5,
        imageTypesLookup: (@Sendable (String) async -> [String]?)? = nil
    ) {
        self.store = store
        self.headless = headless
        self.vospace = vospace
        self.username = username
        self.probeJobTimeout = probeJobTimeout
        self.pollInterval = pollInterval
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
        self.imageTypesLookup = imageTypesLookup
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
        return manifest
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

    /// Pure decision: which strategy applies to this image's types.
    /// Headless-capable → in-target probe. Anything else → inspector.
    static func strategy(forTypes types: [String]?) -> ProbeStrategy {
        guard let types else { return .inTarget }    // unknown: best-effort
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
    private func launchProbeJobWithRetry(for imageID: String) async throws -> String {
        try await retryingOnSkahaRace(label: "probe", imageID: imageID) {
            try await self.launchProbeJob(for: imageID)
        }
    }

    /// Same retry envelope around the inspector launch path. The
    /// race is at submission time (Skaha + K8s API server), not
    /// strategy-specific — both probe and inspector launches go
    /// through the same Skaha endpoint and hit the same race.
    private func launchInspectorJobWithRetry(for targetImageID: String) async throws -> String {
        try await retryingOnSkahaRace(label: "inspector", imageID: targetImageID) {
            try await self.launchInspectorJob(for: targetImageID)
        }
    }

    /// Single shared retry harness used by both strategies. Keeps
    /// the race detection + backoff in one place so future
    /// adjustments (e.g. a second retry, exponential backoff)
    /// only need editing here.
    private func retryingOnSkahaRace<T: Sendable>(
        label: String,
        imageID: String,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await work()
        } catch {
            guard Self.isSkahaJobNotFoundRace(error) else { throw error }
            Self.logger.notice("\(label, privacy: .public) submit hit jobs.batch not-found race for \(imageID, privacy: .public); retrying after 2.5s")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            return try await work()
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
        let safeTarget = ImageManifest.sanitize(imageID: targetImageID).lowercased()
        let trimmed = String(safeTarget.prefix(40))
        let shortUUID = String(UUID().uuidString.prefix(8)).lowercased()
        let jobName = "verbinal-inspect-\(trimmed)-\(shortUUID)"
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let scriptPath = "/arc/home/\(username)/\(ProbeScript.homeSubdirectory)/\(InspectorScript.uploadFilename)"
        let inspectorImage = InspectorScript.resolvedInspectorImageID()
        let params = HeadlessLaunchParams(
            name: jobName,
            image: inspectorImage,           // known-good headless host
            cmd: "bash",
            args: scriptPath,
            env: [("TARGET_IMAGE", targetImageID)],
            cores: 1,
            ram: 4,                          // syft + image pull may want more headroom
            gpus: 0,
            replicas: 1
        )
        let ids = try await headless.launchHeadlessJob(params)
        guard let first = ids.first else {
            throw ImageDiscoveryError.jobSubmitFailed(message: "Skaha returned no job id")
        }
        return first
    }

    private func launchProbeJob(for imageID: String) async throws -> String {
        let safeID = ImageManifest.sanitize(imageID: imageID).lowercased()
        // Skaha session names have rules (alphanumerics + dashes). Trim
        // pathologically long sanitized ids to keep the name within
        // typical limits.
        let trimmed = String(safeID.prefix(40))
        let shortUUID = String(UUID().uuidString.prefix(8)).lowercased()
        let jobName = "verbinal-probe-\(trimmed)-\(shortUUID)"
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")

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
        let params = HeadlessLaunchParams(
            name: jobName,
            image: imageID,
            cmd: "bash",
            args: scriptPath,
            env: [("IMAGE_ID", imageID)],
            cores: 1,
            ram: 2,
            gpus: 0,
            replicas: 1
        )
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

    // MARK: - Internal state hooks (for tests + cleanup)

    private func clearInFlight(_ imageID: String) {
        inFlight[imageID] = nil
    }

    /// Test hook: pretend we haven't uploaded the probe script yet,
    /// so the next `discover` re-runs the upload path.
    func setProbeScriptNotUploaded() {
        probeScriptUploaded = false
    }

    /// Test hook: snapshot of the in-flight key set.
    func inFlightImageIDs() -> Set<String> {
        Set(inFlight.keys)
    }
}
