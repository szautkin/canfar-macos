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

        /// Auto-complete launched jobs after this many polls.
        /// Default 0 = complete immediately.
        var completeAfterPolls: Int = 0
        private var pollCounts: [String: Int] = [:]

        /// If true, every launched job ends in Failed instead of Completed.
        var failJobs: Bool = false

        func launchHeadlessJob(_ params: HeadlessLaunchParams) async throws -> [String] {
            lock.lock()
            defer { lock.unlock() }
            launchCalls.append(params)
            if let err = launchError { throw err }
            nextID += 1
            let id = "job-\(nextID)"
            let job = makeJob(id: id, status: completeAfterPolls > 0 ? "Pending" : (failJobs ? "Failed" : "Completed"))
            jobs.append(job)
            pollCounts[id] = 0
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

        // Wire the manifest the probe will "produce".
        let imageID = "images.canfar.net/skaha/astroml:24.07"
        let safe = ImageManifest.sanitize(imageID: imageID)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        v.fileContents[path] = sampleManifestJSON(imageID: imageID, packages: ["astropy", "numpy"])

        let coord = makeCoord(store: store, headless: h, vospace: v)

        let manifest = try await coord.discover(imageID)
        XCTAssertEqual(manifest.imageID, imageID)
        XCTAssertEqual(Set(manifest.pythonPackages.map(\.name)), ["astropy", "numpy"])

        // Probe was launched once; image, cmd, env all set correctly.
        XCTAssertEqual(h.launchCalls.count, 1)
        let call = h.launchCalls[0]
        XCTAssertEqual(call.image, imageID)
        XCTAssertTrue(call.cmd?.contains(ProbeScript.uploadFilename) ?? false)
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

        let imageID = "test:slow"
        let safe = ImageManifest.sanitize(imageID: imageID)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        v.fileContents[path] = sampleManifestJSON(imageID: imageID)

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

        let imageID = "test:dir-setup"
        let safe = ImageManifest.sanitize(imageID: imageID)
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
            sampleManifestJSON(imageID: imageID)

        let coord = makeCoord(store: store, headless: h, vospace: v)
        _ = try await coord.discover(imageID)

        XCTAssertEqual(v.foldersCreated.count, 1, "must mkdir exactly once per session")
        XCTAssertEqual(v.foldersCreated[0].folderName, ProbeScript.homeSubdirectory)
        XCTAssertEqual(v.foldersCreated[0].parentPath, "")
    }

    func testProbeJobCmdContainsNoShellExpansion() async throws {
        // Skaha's server-side runs `cmd` through a regex replacer
        // that treats `$X` as a regex group backreference. Any `$`
        // in cmd causes HTTP 400 "Illegal group reference" before
        // the container even starts. Pin the rule: cmd must be a
        // pre-resolved absolute path with no `$` characters at all.
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        let imageID = "test:no-shell-expansion"
        let safe = ImageManifest.sanitize(imageID: imageID)
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
            sampleManifestJSON(imageID: imageID)

        let coord = makeCoord(store: store, headless: h, vospace: v)
        _ = try await coord.discover(imageID)

        XCTAssertEqual(h.launchCalls.count, 1)
        let cmd = h.launchCalls[0].cmd ?? ""
        XCTAssertFalse(cmd.contains("$"),
                       "cmd must not contain `$` (Skaha treats it as a regex group ref); got: \(cmd)")
        XCTAssertTrue(cmd.hasPrefix("bash /arc/home/"),
                      "cmd must use absolute /arc/home path; got: \(cmd)")
        XCTAssertTrue(cmd.contains(ProbeScript.uploadFilename))
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

        let imageID = "test:second-session"
        let safe = ImageManifest.sanitize(imageID: imageID)
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
            sampleManifestJSON(imageID: imageID)

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

        // Five different images all need probing.
        let ids = (1...5).map { "test:img\($0)" }
        for id in ids {
            let safe = ImageManifest.sanitize(imageID: id)
            v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
                sampleManifestJSON(imageID: id)
        }

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

        let imageID = "test:coalesce"
        let safe = ImageManifest.sanitize(imageID: imageID)
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"] =
            sampleManifestJSON(imageID: imageID)

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
        // Pre-seed manifest data for the uncached one.
        let safeC = ImageManifest.sanitize(imageID: "c:1")
        v.fileContents["\(ProbeScript.homeSubdirectory)/manifests/\(safeC).json"] =
            sampleManifestJSON(imageID: "c:1")

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
        guard case .failure(_, let cat, _, _) = outcome else {
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
        guard case .failure(_, let cat, _, _) = outcome else {
            return XCTFail("expected .failure outcome")
        }
        XCTAssertEqual(cat, .manifestFetchFailed)
    }

    // MARK: - Rediscover invalidates first

    func testRediscoverDropsCacheAndRerunsProbe() async throws {
        let store = makeStore()
        let h = MockHeadless()
        let v = MockVOSpace()

        let id = "test:rediscover"
        let safe = ImageManifest.sanitize(imageID: id)
        let path = "\(ProbeScript.homeSubdirectory)/manifests/\(safe).json"
        v.fileContents[path] = sampleManifestJSON(imageID: id, packages: ["v1"])

        let coord = makeCoord(store: store, headless: h, vospace: v)

        let m1 = try await coord.discover(id)
        XCTAssertEqual(m1.pythonPackages.first?.name, "v1")
        XCTAssertEqual(h.launchCalls.count, 1)

        // Update what the "next" probe will produce.
        v.fileContents[path] = sampleManifestJSON(imageID: id, packages: ["v2"])

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
        guard case .failure(_, let cat, _, _) = outcome else {
            return XCTFail("expected .failure outcome")
        }
        XCTAssertEqual(cat, .jobTimedOut)
    }
}
