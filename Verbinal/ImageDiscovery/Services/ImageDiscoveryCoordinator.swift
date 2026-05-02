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
}

/// Just the VOSpace operations the coordinator needs:
/// upload (for the probe script) and download (for the manifest).
protocol VOSpaceFileTransfer: Sendable {
    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws
    func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String)
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

    init(
        store: any ManifestStore,
        headless: any HeadlessProbeLauncher,
        vospace: any VOSpaceFileTransfer,
        username: String,
        probeJobTimeout: TimeInterval = 300,
        pollInterval: TimeInterval = 3,
        maxConcurrentProbes: Int = 5
    ) {
        self.store = store
        self.headless = headless
        self.vospace = vospace
        self.username = username
        self.probeJobTimeout = probeJobTimeout
        self.pollInterval = pollInterval
        self.maxConcurrentProbes = max(1, maxConcurrentProbes)
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
            return try await self.runDiscovery(for: imageID)
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

    private func runDiscovery(for imageID: String) async throws -> ImageManifest {
        do {
            try await ensureProbeScript()
        } catch {
            try? await persistFailure(imageID: imageID,
                                      error: .jobSubmitFailed(message: "probe script upload: \(error.localizedDescription)"))
            throw ImageDiscoveryError.jobSubmitFailed(message: error.localizedDescription)
        }

        let jobID: String
        do {
            jobID = try await launchProbeJob(for: imageID)
        } catch let HeadlessLaunchError.partialReplicaFailure(_, _, msg) {
            let err = ImageDiscoveryError.jobSubmitFailed(message: msg)
            try? await persistFailure(imageID: imageID, error: err)
            throw err
        } catch {
            let err = ImageDiscoveryError.jobSubmitFailed(message: error.localizedDescription)
            try? await persistFailure(imageID: imageID, error: err)
            throw err
        }

        do {
            try await pollUntilTerminal(jobID: jobID)
        } catch {
            let err: ImageDiscoveryError
            if let typed = error as? ImageDiscoveryError {
                err = typed
            } else {
                err = .unknown(message: error.localizedDescription)
            }
            try? await persistFailure(imageID: imageID, error: err)
            throw err
        }

        let data: Data
        do {
            data = try await fetchManifestData(for: imageID)
        } catch {
            let err = ImageDiscoveryError.manifestFetchFailed(message: error.localizedDescription)
            try? await persistFailure(imageID: imageID, error: err)
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
            try? await persistFailure(imageID: imageID, error: err)
            throw err
        } catch {
            let err = ImageDiscoveryError.manifestParseFailed(detail: error.localizedDescription)
            try? await persistFailure(imageID: imageID, error: err)
            throw err
        }

        try await store.setManifest(manifest)
        return manifest
    }

    private func ensureProbeScript() async throws {
        if probeScriptUploaded { return }

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

        let cmd = "bash $HOME/\(ProbeScript.homeSubdirectory)/\(ProbeScript.uploadFilename)"
        let params = HeadlessLaunchParams(
            name: jobName,
            image: imageID,
            cmd: cmd,
            args: nil,
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

    private func persistFailure(imageID: String, error: ImageDiscoveryError) async throws {
        try await store.setFailure(
            imageID: imageID,
            category: error.cacheCategory,
            message: error.displayMessage,
            attemptedAt: Date()
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
