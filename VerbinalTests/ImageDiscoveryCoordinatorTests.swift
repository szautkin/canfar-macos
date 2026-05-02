// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ImageDiscoveryCoordinatorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    // MARK: - Test doubles

    /// Mock launcher with scripted behaviour: each call to
    /// `launchHeadlessJob` returns an id from the queue; getHeadlessJobs
    /// returns the current job table. Tests poke job state to drive
    /// the coordinator's polling loop.
    final class MockHeadless: HeadlessProbeLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var nextID: Int = 0
        private(set) var launchCalls: [HeadlessLaunchParams] = []
        private(set) var jobs: [HeadlessJob] = []
        var launchError: Error?
        /// Errors to throw on consecutive launch calls — first call
        /// dequeues errorSequence[0], second call errorSequence[1],
        /// etc. Empty queue falls back to launchError or success.
        /// Lets retry-path tests assert the exact pattern (e.g.
        /// "first launch fails with race error, second succeeds").
        var launchErrorSequence: [Error] = []

        /// Auto-complete launched jobs after this many polls.
        /// Default 0 = complete immediately.
        var completeAfterPolls: Int = 0
        private var pollCounts: [String: Int] = [:]

        /// If true, every launched job ends in Failed instead of Completed.
        var failJobs: Bool = false

        /// Called inside `launchHeadlessJob` after a successful
        /// launch — lets a test mirror real probe behaviour by
        /// simulating the manifest-write side-effect (the actual
        /// Skaha probe writes a JSON manifest to VOSpace as its
        /// last step). Without this, tests that pre-seed the
        /// VOSpace mock would now hit the coordinator's recovery
        /// short-circuit and skip launching at all.
        var onLaunchSimulate: (@Sendable (HeadlessLaunchParams) -> Void)?

        func launchHeadlessJob(_ params: HeadlessLaunchParams) async throws -> [String] {
            lock.lock()
            defer { lock.unlock() }
            launchCalls.append(params)
            if !launchErrorSequence.isEmpty {
                let err = launchErrorSequence.removeFirst()
                throw err
            }
            if let err = launchError { throw err }
            nextID += 1
            let id = "job-\(nextID)"
            let job = makeJob(id: id, status: completeAfterPolls > 0 ? "Pending" : (failJobs ? "Failed" : "Completed"))
            jobs.append(job)
            pollCounts[id] = 0
            // Side-effect: simulate the probe writing its manifest.
            // Tests can populate VOSpace via this hook so the
            // coordinator's post-poll fetch finds something.
            onLaunchSimulate?(params)
            return [id]
        }

        func getHeadlessJobs() async throws -> [HeadlessJob] {
            lock.lock()
            defer { lock.unlock() }
            // Advance state machine: each poll bumps the count and may
            // flip the job to terminal once threshold is reached.
            var updated: [HeadlessJob] = []
            for var job in jobs {
                let count = (pollCounts[job.id] ?? 0) + 1
                pollCounts[job.id] = count
                if !job.isTerminal && count >= completeAfterPolls && completeAfterPolls > 0 {
                    job.status = failJobs ? "Failed" : "Completed"
                }
                updated.append(job)
            }
            jobs = updated
            return jobs
        }

        var stubbedLogs: [String: String] = [:]
        var stubbedEvents: [String: String] = [:]

        func getLogs(id: String) async throws -> String {
            lock.lock()
            defer { lock.unlock() }
            return stubbedLogs[id] ?? ""
        }

        func getEvents(id: String) async throws -> String {
            lock.lock()
            defer { lock.unlock() }
            return stubbedEvents[id] ?? ""
        }

        private func makeJob(id: String, status: String) -> HeadlessJob {
            let raw = SkahaHeadlessResponse(
                id: id, userid: "test", image: "x", type: "headless",
                status: status, name: "verbinal-probe-\(id)",
                startTime: nil, expiryTime: nil, connectURL: nil,
                requestedRAM: nil, requestedCPUCores: nil, requestedGPUCores: nil,
                ramInUse: nil, cpuCoresInUse: nil, isFixedResources: false
            )
            return HeadlessJob(from: raw)
        }
    }

    /// Mock VOSpace transfer. Holds a path → Data dictionary; uploads
    /// write to a "remote" tempdir, downloads return content from the
    /// dictionary or an injectable error.
    final class MockVOSpace: VOSpaceFileTransfer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var uploads: [(remotePath: String, content: Data)] = []
        private(set) var foldersCreated: [(parentPath: String, folderName: String)] = []
        var fileContents: [String: Data] = [:]
        var downloadError: Error?
        var uploadError: Error?
        var createFolderError: Error?

        func uploadFile(username: String, remotePath: String, fileURL: URL) async throws {
            lock.lock()
            defer { lock.unlock() }
            if let err = uploadError { throw err }
            let content = (try? Data(contentsOf: fileURL)) ?? Data()
            uploads.append((remotePath: remotePath, content: content))
        }

        func downloadFile(username: String, path: String) async throws -> (tempURL: URL, filename: String) {
            lock.lock()
            defer { lock.unlock() }
            if let err = downloadError { throw err }
            guard let data = fileContents[path] else {
                throw NSError(domain: "MockVOSpace", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "no file at \(path)"])
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mock-download-\(UUID().uuidString)")
            try data.write(to: tempURL)
            return (tempURL, (path as NSString).lastPathComponent)
        }

        func createFolder(username: String, parentPath: String, folderName: String) async throws {
            lock.lock()
            defer { lock.unlock() }
            if let err = createFolderError { throw err }
            foldersCreated.append((parentPath: parentPath, folderName: folderName))
        }
    }

    // MARK: - Helpers

    private func makeStore() -> JSONManifestStore {
        JSONManifestStore(directory: tempDir)
    }

    private func makeCoord(
        store: JSONManifestStore,
        headless: MockHeadless,
        vospace: MockVOSpace,
        timeout: TimeInterval = 5.0
    ) -> ImageDiscoveryCoordinator {
        ImageDiscoveryCoordinator(
            store: store,
            headless: headless,
            vospace: vospace,
            username: "testuser",
            probeJobTimeout: timeout,
            pollInterval: 0.01,         // fast polling for tests
            maxConcurrentProbes: 3
        )
    }

    /// Wire the mock pair so that any launch produces a manifest
    /// at the expected VOSpace path for the launched image — the
    /// realistic probe behaviour. Tests verifying the launch path
    /// call this once at setup; tests verifying the recovery path
    /// (manifest already in VOSpace) skip it and pre-seed
    /// `vospace.fileContents` directly instead.
    private func wireLaunchToWriteManifest(
        _ vospace: MockVOSpace,
        _ headless: MockHeadless,
        packages: [String] = ["astropy"]
    ) {
        let json: @Sendable (String) -> Data = { imageID in
            self.sampleManifestJSON(imageID: imageID, packages: packages)
        }
        headless.onLaunchSimulate = { [weak vospace] params in
            let safe = ImageManifest.sanitize(imageID: params.image)
            let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
            vospace?.fileContents[path] = json(params.image)
        }
    }

    private func sampleManifestJSON(imageID: String, packages: [String] = ["astropy"]) -> Data {
        let body: [String: Any] = [
            "schemaVersion": 1,
            "imageID": imageID,
            "contentHash": "sha256:test",
            "capturedAt": "2026-04-30T18:00:00Z",
            "osFamily": "ubuntu",
            "osVersion": "22.04",
            "kernel": "Linux",
            "dpkgPackages": [],
            "rpmPackages": [],
            "apkPackages": [],
            "pythonPackages": packages.map { ["name": $0, "version": "1.0", "source": "pip", "env": "base"] },
            "rPackages": [],
            "condaEnvs": []
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Cache hit short-circuits

    func testDiscoverReturnsCachedManifestWithoutProbe() async throws {
        let store = makeStore()
        let cached = ImageManifest(
            schemaVersion: 1,
            imageID: "test:1",
            contentHash: "sha256:cached",
            capturedAt: Date(),
            osFamily: "ubuntu",
            osVersion: "22.04",
            kernel: "Linux"
        )
        try await store.setManifest(cached)

        let h = MockHeadless()
        let v = MockVOSpace()
        let coord = makeCoord(store: store, headless: h, vospace: v)

        let got = try await coord.discover("test:1")
        XCTAssertEqual(got.imageID, "test:1")
        XCTAssertEqual(got.contentHash, "sha256:cached")
        XCTAssertTrue(h.launchCalls.isEmpty, "must not probe on cache hit")
        XCTAssertTrue(v.uploads.isEmpty)
    }

    // MARK: - Full pipeline

    func testDiscoverRunsFullPipelineForUncachedImage() async throws {
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        // Probe job side-effect: writes the manifest to the
        // expected VOSpace path. Mirrors real Skaha behaviour.
        let imageID = "images.canfar.net/skaha/astroml:24.07"
        wireLaunchToWriteManifest(v, h, packages: ["astropy", "numpy"])

        let coord = makeCoord(store: store, headless: h, vospace: v)

        let manifest = try await coord.discover(imageID)
        XCTAssertEqual(manifest.imageID, imageID)
        XCTAssertEqual(Set(manifest.pythonPackages.map(\.name)), ["astropy", "numpy"])

        // Probe was launched once; image, cmd/args, env all set correctly.
        // The cmd is just "bash" and the script path lives in args
        // (Skaha hands cmd to OCI verbatim and would fail to find a
        // binary named "bash /path/script.sh" with the space).
        XCTAssertEqual(h.launchCalls.count, 1)
        let call = h.launchCalls[0]
        XCTAssertEqual(call.image, imageID)
        XCTAssertEqual(call.cmd, "bash")
        XCTAssertTrue(call.args?.contains(ProbeScript.uploadFilename) ?? false,
                      "script path must live in args, not cmd; got args: \(call.args ?? "nil")")
        XCTAssertEqual(call.env.first(where: { $0.0 == "IMAGE_ID" })?.1, imageID)

        // Probe script was uploaded.
        XCTAssertEqual(v.uploads.count, 1)
        XCTAssertEqual(v.uploads[0].remotePath, "\(ProbeScript.homeSubdirectory)/\(ProbeScript.uploadFilename)")

        // Manifest persisted to cache.
        let outcome = await store.outcome(for: imageID)
        XCTAssertTrue(outcome?.isSuccess ?? false)
    }

    func testDiscoverPollsUntilTerminal() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.completeAfterPolls = 3   // 3 polls then flip to Completed
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        let imageID = "test:slow"
        let coord = makeCoord(store: store, headless: h, vospace: v, timeout: 5.0)

        let manifest = try await coord.discover(imageID)
        XCTAssertEqual(manifest.imageID, imageID)
    }

    // MARK: - VOSpace dir setup

    func testProbeScriptUploadCreatesParentDirFirst() async throws {
        // Real-world bug: VOSpace returns HTTP 404 on PUT to a path
        // whose parent doesn't exist. The coordinator must mkdir
        // .verbinal BEFORE uploading probe-<hash>.sh.
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        let coord = makeCoord(store: store, headless: h, vospace: v)
        _ = try await coord.discover("test:dir-setup")

        XCTAssertEqual(v.foldersCreated.count, 1, "must mkdir exactly once per session")
        XCTAssertEqual(v.foldersCreated[0].folderName, ProbeScript.homeSubdirectory)
        XCTAssertEqual(v.foldersCreated[0].parentPath, "")
    }

    func testProbeJobCmdAndArgsAreSplitCorrectly() async throws {
        // Skaha passes `cmd` to OCI as the binary name verbatim —
        // no shell parsing. Joining "bash" + path into one cmd
        // string makes containerd look for an executable literally
        // named "bash /path/script.sh" (including the space) and
        // fail with `exec: ... no such file or directory`. The
        // probe must split cmd ("bash") and args (the script path).
        // Pin the rule so this can't regress.
        //
        // Also: cmd must contain no `$` because Skaha runs cmd
        // through a Java regex replacer that treats `$X` as a
        // group backreference (the prior $HOME bug).
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        let imageID = "test:cmd-args-split"
        let coord = makeCoord(store: store, headless: h, vospace: v)
        _ = try await coord.discover(imageID)

        XCTAssertEqual(h.launchCalls.count, 1)
        let cmd = h.launchCalls[0].cmd ?? ""
        let args = h.launchCalls[0].args ?? ""

        XCTAssertEqual(cmd, "bash",
                       "cmd must be just the binary name; got: \(cmd)")
        XCTAssertFalse(cmd.contains(" "),
                       "cmd must not contain spaces (OCI parses it as a single binary path)")
        XCTAssertFalse(cmd.contains("$"),
                       "cmd must not contain `$` (Skaha regex-replacer treats it as a backreference)")

        XCTAssertTrue(args.hasPrefix("/arc/home/"),
                      "args must be the absolute script path; got: \(args)")
        XCTAssertTrue(args.contains(ProbeScript.uploadFilename))
        XCTAssertFalse(args.contains(" "),
                       "args must be a single space-free token (Skaha tokenises args by whitespace)")
        XCTAssertFalse(args.contains("$"))
    }

    func testProbeScriptUploadSwallowsAlreadyExistsMkdirError() async throws {
        // After the first session, .verbinal already exists. createFolder
        // returns an error (409 / "already exists"). The coordinator
        // must swallow it and proceed to the upload, otherwise every
        // post-first-launch discovery breaks.
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()
        v.createFolderError = NSError(domain: "VOSpace", code: 409,
                                       userInfo: [NSLocalizedDescriptionKey: "already exists"])
        wireLaunchToWriteManifest(v, h)

        let imageID = "test:second-session"
        let coord = makeCoord(store: store, headless: h, vospace: v)
        let manifest = try await coord.discover(imageID)
        XCTAssertEqual(manifest.imageID, imageID)
        XCTAssertEqual(v.uploads.count, 1, "upload must proceed after swallowed mkdir error")
    }

    // MARK: - Probe script upload-once

    func testProbeScriptUploadedOnceAcrossManyDiscoveries() async throws {
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        // Five different images all need probing.
        let ids = (1...5).map { "test:img\($0)" }
        let coord = makeCoord(store: store, headless: h, vospace: v)
        for id in ids {
            _ = try await coord.discover(id)
        }

        XCTAssertEqual(v.uploads.count, 1, "probe script must upload exactly once per session")
        XCTAssertEqual(h.launchCalls.count, 5, "each image still gets its own probe job")
    }

    // MARK: - Coalescing

    func testConcurrentDiscoverCallsForSameImageCoalesce() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.completeAfterPolls = 5   // give us time for coalescing to bite
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        let imageID = "test:coalesce"
        let coord = makeCoord(store: store, headless: h, vospace: v)

        // Five concurrent callers asking for the same image.
        async let a = coord.discover(imageID)
        async let b = coord.discover(imageID)
        async let c = coord.discover(imageID)
        async let d = coord.discover(imageID)
        async let e = coord.discover(imageID)

        let results = try await [a, b, c, d, e]
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0.imageID == imageID })

        // Only ONE probe job launched despite five callers.
        XCTAssertEqual(h.launchCalls.count, 1, "five callers must collapse to one probe")
    }

    // MARK: - Streaming batch

    func testDiscoverAllStreamsCompletionEventsInOrderOfFinish() async throws {
        let store = makeStore()
        // Pre-cache two images so they yield .completed instantly.
        let cachedA = ImageManifest(schemaVersion: 1, imageID: "a:1",
                                     contentHash: "x", capturedAt: Date(),
                                     osFamily: "ubuntu", osVersion: "22.04", kernel: "Linux")
        let cachedB = ImageManifest(schemaVersion: 1, imageID: "b:1",
                                     contentHash: "x", capturedAt: Date(),
                                     osFamily: "ubuntu", osVersion: "22.04", kernel: "Linux")
        try await store.setManifest(cachedA)
        try await store.setManifest(cachedB)

        let h = MockHeadless()
        let v = MockVOSpace()
        // Probe writes the manifest for the uncached image c:1.
        wireLaunchToWriteManifest(v, h)

        let coord = makeCoord(store: store, headless: h, vospace: v)

        var events: [DiscoveryEvent] = []
        for await e in coord.discoverAll(["a:1", "b:1", "c:1"]) {
            events.append(e)
        }

        // Three .completed events; cache hits don't yield .started.
        let completedIDs = events.compactMap { e -> String? in
            if case .completed(let id, _) = e { return id } else { return nil }
        }
        XCTAssertEqual(Set(completedIDs), Set(["a:1", "b:1", "c:1"]))

        // c:1 should have a .started before its .completed (it's a miss).
        let cStart = events.firstIndex { e in
            if case .started("c:1") = e { return true } else { return false }
        }
        let cComplete = events.firstIndex { e in
            if case .completed(let id, _) = e { return id == "c:1" } else { return false }
        }
        XCTAssertNotNil(cStart)
        XCTAssertNotNil(cComplete)
        XCTAssertLessThan(cStart!, cComplete!)
    }

    // MARK: - Failures persist + propagate

    func testJobLaunchFailurePersistsCacheEntry() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.launchError = NSError(domain: "Skaha", code: 400,
                                userInfo: [NSLocalizedDescriptionKey: "private image"])
        let v = MockVOSpace()

        let coord = makeCoord(store: store, headless: h, vospace: v)

        do {
            _ = try await coord.discover("private:1")
            XCTFail("expected throw")
        } catch let err as ImageDiscoveryError {
            guard case .jobSubmitFailed = err else {
                return XCTFail("expected jobSubmitFailed, got \(err)")
            }
        }

        // Cache should now hold a .failure for this image.
        let outcome = await store.outcome(for: "private:1")
        guard case .failure(_, let cat, _, _, _) = outcome else {
            return XCTFail("expected .failure outcome")
        }
        XCTAssertEqual(cat, .jobSubmitFailed)
    }

    func testManifestFetchFailurePersistsCacheEntry() async throws {
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()
        // Leave fileContents empty so the download throws 404.

        let coord = makeCoord(store: store, headless: h, vospace: v)

        do {
            _ = try await coord.discover("missing:1")
            XCTFail("expected throw")
        } catch let err as ImageDiscoveryError {
            guard case .manifestFetchFailed = err else {
                return XCTFail("expected manifestFetchFailed, got \(err)")
            }
        }

        let outcome = await store.outcome(for: "missing:1")
        guard case .failure(_, let cat, _, _, _) = outcome else {
            return XCTFail("expected .failure outcome")
        }
        XCTAssertEqual(cat, .manifestFetchFailed)
    }

    // MARK: - Probe strategy router

    func testStrategyChoiceFromTypes() {
        // headless-capable image → in-target probe
        XCTAssertEqual(
            ImageDiscoveryCoordinator.strategy(forTypes: ["headless"]),
            .inTarget
        )
        XCTAssertEqual(
            ImageDiscoveryCoordinator.strategy(forTypes: ["notebook", "headless"]),
            .inTarget
        )
        // No headless type → inspector
        XCTAssertEqual(
            ImageDiscoveryCoordinator.strategy(forTypes: ["notebook"]),
            .inspector
        )
        XCTAssertEqual(
            ImageDiscoveryCoordinator.strategy(forTypes: ["carta"]),
            .inspector
        )
        XCTAssertEqual(
            ImageDiscoveryCoordinator.strategy(forTypes: []),
            .inspector
        )
        // Unknown types (lookup returned nil) → in-target fallback
        XCTAssertEqual(
            ImageDiscoveryCoordinator.strategy(forTypes: nil),
            .inTarget
        )
    }

    func testInspectorPathLaunchesKnownGoodImageWithTargetEnv() async throws {
        // Non-headless target → coordinator picks inspector strategy.
        // Pin the wire shape: cmd is "bash", args points at the
        // *inspector* script (not probe-*.sh), image is the
        // *inspector* image (not the target), env carries
        // TARGET_IMAGE=<the original target>.
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        // Inspector path writes the manifest at the path for the
        // TARGET image (carried via TARGET_IMAGE env), NOT the
        // inspector container image.
        h.onLaunchSimulate = { [weak v] params in
            guard let target = params.env.first(where: { $0.0 == "TARGET_IMAGE" })?.1 else { return }
            let safe = ImageManifest.sanitize(imageID: target)
            let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
            v?.fileContents[path] = self.sampleManifestJSON(imageID: target)
        }

        let nonHeadlessImage = "images.canfar.net/skaha/notebook:24.07"
        let coord = ImageDiscoveryCoordinator(
            store: store,
            headless: h,
            vospace: v,
            username: "testuser",
            probeJobTimeout: 5.0,
            pollInterval: 0.01,
            maxConcurrentProbes: 3,
            imageTypesLookup: { id in
                id == nonHeadlessImage ? ["notebook"] : nil
            }
        )

        _ = try await coord.discover(nonHeadlessImage)

        XCTAssertEqual(h.launchCalls.count, 1)
        let call = h.launchCalls[0]
        XCTAssertEqual(call.image, InspectorScript.builtinInspectorImageID,
                       "inspector path must launch the known-good headless image, NOT the target")
        XCTAssertEqual(call.cmd, "bash")
        XCTAssertTrue(call.args?.contains(InspectorScript.uploadFilename) ?? false,
                      "args must point at the inspector script; got \(call.args ?? "nil")")
        XCTAssertEqual(call.env.first(where: { $0.0 == "TARGET_IMAGE" })?.1, nonHeadlessImage,
                       "target image id must be passed via TARGET_IMAGE env")
    }

    func testHeadlessImageStillUsesInTargetPath() async throws {
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        let headlessImage = "images.canfar.net/skaha/terminal:1.1.2"
        let coord = ImageDiscoveryCoordinator(
            store: store, headless: h, vospace: v, username: "testuser",
            probeJobTimeout: 5.0, pollInterval: 0.01, maxConcurrentProbes: 3,
            imageTypesLookup: { _ in ["headless"] }
        )

        _ = try await coord.discover(headlessImage)

        XCTAssertEqual(h.launchCalls.count, 1)
        let call = h.launchCalls[0]
        XCTAssertEqual(call.image, headlessImage,
                       "in-target path launches the target image as the probe host")
        XCTAssertTrue(call.args?.contains(ProbeScript.uploadFilename) ?? false,
                      "in-target path uses probe.sh, not inspector.sh")
    }

    func testInspectorScriptInvariants() {
        // Pin the contract: schemaVersion matches the parser's max,
        // body references the env var the coordinator sets, and the
        // upload filename is hash-derived (so bumping the body busts
        // the prior upload automatically).
        XCTAssertEqual(InspectorScript.schemaVersion, ManifestParser.maxSupportedSchemaVersion)
        XCTAssertTrue(InspectorScript.body.contains("TARGET_IMAGE"))
        XCTAssertTrue(InspectorScript.body.contains(".verbinal/manifests"))
        XCTAssertTrue(InspectorScript.body.contains("syft"))
        XCTAssertEqual(InspectorScript.uploadFilename, "inspector-\(InspectorScript.scriptHash).sh")
        XCTAssertEqual(InspectorScript.scriptHash.count, 12)
    }

    // MARK: - VOSpace manifest recovery

    func testDiscoverShortCircuitsIfManifestAlreadyInVOSpace() async throws {
        // Real-world bug surface: a previous probe completed and
        // wrote its manifest to VOSpace, but our poll loop timed
        // out before catching its terminal state. The cache holds
        // no record. On a subsequent discover() call we should
        // *not* re-launch a probe — the manifest is sitting at
        // the expected path, fetch it directly.
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        let imageID = "test:already-probed"
        let safe = ImageManifest.sanitize(imageID: imageID)
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
            sampleManifestJSON(imageID: imageID, packages: ["recovered"])

        let coord = makeCoord(store: store, headless: h, vospace: v)

        let manifest = try await coord.discover(imageID)

        XCTAssertEqual(manifest.imageID, imageID)
        XCTAssertEqual(manifest.pythonPackages.first?.name, "recovered")
        XCTAssertEqual(h.launchCalls.count, 0,
                       "must not launch a fresh probe when VOSpace already has the manifest")
    }

    func testRediscoverIgnoresPreExistingManifestAndForcesProbe() async throws {
        // Force-rediscover means the user explicitly wants a fresh
        // probe even if a manifest sits in VOSpace. Otherwise the
        // recovery short-circuit would defeat the user's intent.
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        let imageID = "test:force-rediscover"
        let safe = ImageManifest.sanitize(imageID: imageID)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        // Pre-existing stale manifest from a previous probe:
        v.fileContents[path] = sampleManifestJSON(imageID: imageID, packages: ["stale"])

        let coord = makeCoord(store: store, headless: h, vospace: v)

        // First discover() picks up the pre-existing manifest (recovery
        // short-circuit; no probe launched).
        let m1 = try await coord.discover(imageID)
        XCTAssertEqual(m1.pythonPackages.first?.name, "stale")
        XCTAssertEqual(h.launchCalls.count, 0)

        // Now the probe will produce an updated manifest:
        v.fileContents[path] = sampleManifestJSON(imageID: imageID, packages: ["fresh"])

        // rediscover bypasses BOTH cache and VOSpace pre-check:
        let m2 = try await coord.rediscover(imageID)
        XCTAssertEqual(m2.pythonPackages.first?.name, "fresh")
        XCTAssertEqual(h.launchCalls.count, 1, "rediscover must actually launch a fresh probe")
    }

    func testTimeoutFallsThroughToManifestFetchIfFileLanded() async throws {
        // The poll loop hits its deadline, but the probe job
        // *did* finish and wrote the manifest. Fetching it before
        // surfacing the timeout error saves the user from manually
        // re-running.
        let store = makeStore()
        let h = MockHeadless()
        h.completeAfterPolls = 9999     // never reaches terminal in poll loop
        let v = MockVOSpace()

        let imageID = "test:landed-after-timeout"
        let safe = ImageManifest.sanitize(imageID: imageID)
        // Manifest IS in VOSpace by the time poll times out:
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
            sampleManifestJSON(imageID: imageID, packages: ["completed-late"])

        let coord = makeCoord(store: store, headless: h, vospace: v, timeout: 0.05)

        let manifest = try await coord.discover(imageID)
        XCTAssertEqual(manifest.pythonPackages.first?.name, "completed-late")
    }

    // MARK: - Skaha race retry (F-31)

    func testIsSkahaJobNotFoundRaceMatchesActualErrorBody() {
        // Pin the pattern detector against the actual body Skaha
        // returned in the field. Bigger letters / different
        // wording must NOT match (we only retry on the exact race).
        let raceErr = NSError(
            domain: "Skaha", code: 500,
            userInfo: [NSLocalizedDescriptionKey: """
                HTTP 500: unexpected exception: java.lang.RuntimeException: \
                io.kubernetes.client.openapi.ApiException: Message: \
                HTTP response code: 404 \
                HTTP response body: {"kind":"Status","apiVersion":"v1","metadata":{},\
                "status":"Failure","message":"jobs.batch \\"skaha-headless-szautkin-nie3d4qu\\" not found",\
                "reason":"NotFound","details":{"name":"skaha-headless-szautkin-nie3d4qu","group":"batch","kind":"jobs"},"code":404}
                """]
        )
        XCTAssertTrue(ImageDiscoveryCoordinator.isSkahaJobNotFoundRace(raceErr))

        let unrelated500 = NSError(
            domain: "Skaha", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 500: image pull failed"]
        )
        XCTAssertFalse(ImageDiscoveryCoordinator.isSkahaJobNotFoundRace(unrelated500))

        let real404 = NSError(
            domain: "Skaha", code: 404,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 404: image not found"]
        )
        XCTAssertFalse(ImageDiscoveryCoordinator.isSkahaJobNotFoundRace(real404))
    }

    func testProbeRetriesOnceOnSkahaJobNotFoundRace() async throws {
        let store = makeStore()
        let h = MockHeadless()
        // Fail the FIRST launch with the race error; succeed on retry.
        h.launchErrorSequence = [
            NSError(
                domain: "Skaha", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 500: jobs.batch \"x-y\" not found"]
            )
        ]
        let v = MockVOSpace()
        wireLaunchToWriteManifest(v, h)

        let imageID = "test:race-survives"
        let coord = makeCoord(store: store, headless: h, vospace: v)
        let manifest = try await coord.discover(imageID)
        XCTAssertEqual(manifest.imageID, imageID)
        XCTAssertEqual(h.launchCalls.count, 2,
                       "launch must be retried once after the race-pattern error; got \(h.launchCalls.count) calls")
    }

    func testInspectorPathAlsoRetriesOnSkahaJobNotFoundRace() async throws {
        // The K8s race fires at job-submission time inside Skaha,
        // not specific to the strategy. The inspector path must
        // wear the same retry harness as the in-target path.
        let store = makeStore()
        let h = MockHeadless()
        h.launchErrorSequence = [
            NSError(
                domain: "Skaha", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 500: jobs.batch \"x\" not found"]
            )
        ]
        let v = MockVOSpace()
        h.onLaunchSimulate = { [weak v] params in
            // Inspector path: write at TARGET_IMAGE's path.
            guard let target = params.env.first(where: { $0.0 == "TARGET_IMAGE" })?.1 else { return }
            let safe = ImageManifest.sanitize(imageID: target)
            let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
            v?.fileContents[path] = self.sampleManifestJSON(imageID: target)
        }

        let coord = ImageDiscoveryCoordinator(
            store: store, headless: h, vospace: v, username: "testuser",
            probeJobTimeout: 5.0, pollInterval: 0.01, maxConcurrentProbes: 3,
            imageTypesLookup: { _ in ["notebook"] }     // forces inspector strategy
        )

        _ = try await coord.discover("images.canfar.net/cirada/notebook:1")

        XCTAssertEqual(h.launchCalls.count, 2,
                       "inspector launch must retry once on the K8s race; got \(h.launchCalls.count)")
    }

    func testFriendlyRaceErrorSurvivesOuterCatchAfterRetryExhaust() async throws {
        // Both the original launch AND the 2.5s retry hit the race
        // pattern → retryingOnSkahaRace rewraps as
        // ImageDiscoveryError.jobSubmitFailed("Skaha refused…").
        // The OUTER catch in runDiscovery used to take
        // .localizedDescription on this typed error which fell
        // through to Cocoa's "(Verbinal.ImageDiscoveryError
        // error 0.)" because we didn't conform to LocalizedError,
        // and re-wrapped, producing a nonsense message in the UI.
        // Pin the contract: the friendly message must round-trip
        // unchanged through the outer catch.
        let store = makeStore()
        let h = MockHeadless()
        h.launchErrorSequence = [
            NSError(domain: "Skaha", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP 500: jobs.batch \"x\" not found"]),
            NSError(domain: "Skaha", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP 500: jobs.batch \"x\" not found"])
        ]
        let v = MockVOSpace()

        let coord = makeCoord(store: store, headless: h, vospace: v)

        do {
            _ = try await coord.discover("test:race-exhausted")
            XCTFail("expected throw after both retries hit the race")
        } catch let err as ImageDiscoveryError {
            // Must NOT be the Cocoa "error 0" fallback wrapped.
            XCTAssertFalse(err.displayMessage.contains("error 0"),
                           "raw Error.localizedDescription leaked into the typed error; got: \(err.displayMessage)")
            XCTAssertTrue(err.displayMessage.contains("Skaha refused"),
                          "friendly message must survive outer catch; got: \(err.displayMessage)")
            // LocalizedError conformance — .localizedDescription
            // must return the same friendly text.
            XCTAssertEqual(err.localizedDescription, err.displayMessage)
        }
    }

    func testProbeDoesNotRetryOnUnrelated500() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.launchErrorSequence = [
            NSError(domain: "Skaha", code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP 500: image pull backoff"])
        ]
        let v = MockVOSpace()

        let coord = makeCoord(store: store, headless: h, vospace: v)
        do {
            _ = try await coord.discover("test:no-retry")
            XCTFail("expected throw on first launch")
        } catch is ImageDiscoveryError {
            // expected
        }
        XCTAssertEqual(h.launchCalls.count, 1,
                       "non-race errors must not retry; got \(h.launchCalls.count)")
    }

    // MARK: - Failure jobID capture + log fetch

    func testJobFailureCapturesJobIDInCacheForDiagnostics() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.failJobs = true   // every launched job ends Failed
        let v = MockVOSpace()

        let coord = makeCoord(store: store, headless: h, vospace: v)

        do {
            _ = try await coord.discover("test:badimage")
            XCTFail("expected throw")
        } catch is ImageDiscoveryError {
            // expected
        }

        let outcome = await store.outcome(for: "test:badimage")
        guard case .failure(_, _, _, _, let jobID) = outcome else {
            return XCTFail("expected .failure outcome")
        }
        XCTAssertNotNil(jobID, "jobID must be captured for post-launch failures so the user can fetch logs")
        XCTAssertTrue(jobID?.hasPrefix("job-") ?? false)
    }

    func testFetchLogsAndEventsRouteThroughHeadless() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.stubbedLogs["session-42"] = "Traceback (most recent call last):\n  ImportError: ..."
        h.stubbedEvents["session-42"] = "Successfully pulled image\nContainer started"
        let v = MockVOSpace()

        let coord = makeCoord(store: store, headless: h, vospace: v)

        let logs = try await coord.fetchLogs(jobID: "session-42")
        XCTAssertTrue(logs.contains("Traceback"))

        let events = try await coord.fetchEvents(jobID: "session-42")
        XCTAssertTrue(events.contains("Container started"))
    }

    // MARK: - Rediscover invalidates first

    func testRediscoverDropsCacheAndRerunsProbe() async throws {
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        let id = "test:rediscover"
        let safe = ImageManifest.sanitize(imageID: id)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"

        // First call uses the launch path: the probe writes "v1" to
        // VOSpace and the coordinator picks it up post-poll.
        h.onLaunchSimulate = { [weak v] _ in
            v?.fileContents[path] = self.sampleManifestJSON(imageID: id, packages: ["v1"])
        }

        let coord = makeCoord(store: store, headless: h, vospace: v)
        let m1 = try await coord.discover(id)
        XCTAssertEqual(m1.pythonPackages.first?.name, "v1")
        XCTAssertEqual(h.launchCalls.count, 1)

        // Now: rediscover invalidates cache AND bypasses the
        // VOSpace-recovery short-circuit, so it must launch a
        // fresh probe even though the manifest sits in VOSpace.
        // Wire the next probe to write "v2" to VOSpace.
        h.onLaunchSimulate = { [weak v] _ in
            v?.fileContents[path] = self.sampleManifestJSON(imageID: id, packages: ["v2"])
        }

        let m2 = try await coord.rediscover(id)
        XCTAssertEqual(m2.pythonPackages.first?.name, "v2")
        XCTAssertEqual(h.launchCalls.count, 2, "rediscover must launch a fresh probe")
    }

    // MARK: - Timeout

    func testProbeTimeoutPersistsCacheFailure() async throws {
        let store = makeStore()
        let h = MockHeadless()
        h.completeAfterPolls = 9999   // never completes within timeout
        let v = MockVOSpace()

        let coord = makeCoord(store: store, headless: h, vospace: v, timeout: 0.05)

        do {
            _ = try await coord.discover("test:slow")
            XCTFail("expected timeout throw")
        } catch let err as ImageDiscoveryError {
            XCTAssertEqual(err, .jobTimedOut)
        }

        let outcome = await store.outcome(for: "test:slow")
        guard case .failure(_, let cat, _, _, _) = outcome else {
            return XCTFail("expected .failure outcome")
        }
        XCTAssertEqual(cat, .jobTimedOut)
    }
}
