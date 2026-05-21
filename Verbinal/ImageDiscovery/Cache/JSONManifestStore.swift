// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Per-image JSON file conformance of `ManifestStore`. One file per
/// image id at `<directory>/<sanitized-id>.json`, holding the full
/// `LastOutcome` (success or failure). An in-memory mirror keeps
/// query latency low — at typical scale (~110 images, ~1000 unique
/// packages each) the index fits in a few MB and intersect-style
/// queries run in <5 ms.
///
/// Concurrency: actor-isolated. Filesystem writes use `Data.write(
/// to:options: .atomic)` which is temp-write + rename, so a crash
/// mid-write can't corrupt an existing record. Hydration is lazy
/// on first access (see `ensureHydrated`).
///
/// Why a fresh implementation instead of `DiskPersistence<T>`: that
/// type holds one Codable per store; per-image granularity here is
/// load-bearing because (a) parallel writes from concurrent probes
/// must not contend on a single dictionary file, and (b) cache
/// growth is tens of files of ~50KB rather than one growing JSON
/// blob the disk re-serializes on every update.
actor JSONManifestStore: ManifestStore {

    private static let logger = Logger(
        subsystem: "com.codebg.Verbinal",
        category: "ImageDiscovery.cache"
    )

    /// Directory the store owns. Created at hydration time if
    /// absent. Caller passes a sandboxed App Support subpath in
    /// the production wiring; tests pass a tempdir.
    private let directory: URL

    /// In-memory mirror, keyed by image id. Hydrated lazily.
    private var loaded: [String: LastOutcome] = [:]
    private var hydrated: Bool = false

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Bootstrap (explicit for pre-warm; lazy otherwise)

    /// Pre-load the in-memory index. Optional — every public read
    /// will trigger hydration if it hasn't run. Callers wanting a
    /// "fully loaded before first query" guarantee can `await
    /// store.bootstrap()` at app launch.
    func bootstrap() {
        ensureHydrated()
    }

    private func ensureHydrated() {
        guard !hydrated else { return }
        hydrated = true

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("create cache dir failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            Self.logger.error("list cache dir failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        for url in contents where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let outcome = try decoder.decode(LastOutcome.self, from: data)
                // Both .success and .failure carry the imageID; use it
                // as the cache key directly (don't reverse-engineer
                // from the sanitized filename).
                loaded[outcome.imageID] = outcome
            } catch {
                Self.logger.warning("skip unreadable cache file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        Self.logger.info("hydrated \(self.loaded.count, privacy: .public) cache entries from \(self.directory.path, privacy: .public)")
    }

    // MARK: - ManifestStore

    func outcome(for imageID: String) -> LastOutcome? {
        ensureHydrated()
        return loaded[imageID]
    }

    func setManifest(_ manifest: ImageManifest) throws {
        ensureHydrated()
        let outcome = LastOutcome.success(manifest)
        try persist(outcome: outcome, imageID: manifest.imageID)
        loaded[manifest.imageID] = outcome
    }

    func setFailure(
        imageID: String,
        category: LastOutcome.FailureCategory,
        message: String,
        attemptedAt: Date,
        jobID: String?
    ) throws {
        ensureHydrated()
        let outcome = LastOutcome.failure(
            imageID: imageID,
            category: category,
            message: message,
            attemptedAt: attemptedAt,
            jobID: jobID
        )
        try persist(outcome: outcome, imageID: imageID)
        loaded[imageID] = outcome
    }

    func invalidate(imageID: String) throws {
        ensureHydrated()
        loaded.removeValue(forKey: imageID)
        let url = fileURL(for: imageID)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    func clear() throws {
        ensureHydrated()
        loaded.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for url in contents where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }

    func search(_ query: PackageQuery) -> [String] {
        ensureHydrated()
        var ids: [String] = []
        for (id, outcome) in loaded {
            guard case .success(let manifest) = outcome else { continue }
            if query.isEmpty || query.matches(manifest) {
                ids.append(id)
            }
        }
        return ids.sorted()
    }

    func searchPartial(
        _ query: PackageQuery,
        minScore: Double,
        limit: Int
    ) -> [PartialMatch] {
        ensureHydrated()
        // Empty query is degenerate — every manifest scores 1.0
        // with no missing constraints, which would defeat the
        // purpose. Returning [] here matches the convention that
        // partial-match results are only meaningful when the
        // strict match is empty AND the user supplied filters.
        if query.isEmpty { return [] }
        var results: [PartialMatch] = []
        for (id, outcome) in loaded {
            guard case .success(let manifest) = outcome else { continue }
            let (score, missing) = query.score(manifest)
            if score >= minScore {
                results.append(PartialMatch(imageID: id, score: score, missing: missing))
            }
        }
        // Sort by score desc, then alphabetically by id for stable
        // ordering across calls — agents comparing responses
        // shouldn't see a permuted top-N just because two scores
        // tied.
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.imageID < rhs.imageID
        }
        if results.count > limit {
            results = Array(results.prefix(limit))
        }
        return results
    }

    func knownImages() -> [String] {
        ensureHydrated()
        return loaded.keys.sorted()
    }

    func allPackages() -> AllPackages {
        ensureHydrated()
        var result = AllPackages()
        for (_, outcome) in loaded {
            guard case .success(let m) = outcome else { continue }
            if m.osFamily != "unknown" {
                result.osFamilies.insert(m.osFamily)
                if m.osVersion != "unknown" {
                    result.osVersionsByFamily[m.osFamily, default: []].insert(m.osVersion)
                }
            }
            for p in m.dpkgPackages   { result.dpkg.insert(p.name) }
            for p in m.rpmPackages    { result.rpm.insert(p.name) }
            for p in m.apkPackages    { result.apk.insert(p.name) }
            for p in m.pythonPackages { result.python.insert(p.name) }
            for p in m.rPackages      { result.r.insert(p.name) }
        }
        return result
    }

    func count() -> Int {
        ensureHydrated()
        return loaded.count
    }

    // MARK: - File IO

    private func fileURL(for imageID: String) -> URL {
        let safe = ImageManifest.sanitize(imageID: imageID)
        return directory.appendingPathComponent(safe + ".json")
    }

    private func persist(outcome: LastOutcome, imageID: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = fileURL(for: imageID)
        let data = try encoder.encode(outcome)
        // .atomic = write to temp + rename. Robust against crashes
        // mid-write; concurrent writers on the SAME image id are
        // serialized by the actor.
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Default location

extension JSONManifestStore {
    /// App Support subpath where production stores the cache. Used
    /// by AppState wiring; tests pass an isolated tempdir.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Verbinal", isDirectory: true)
            .appendingPathComponent("ImageDiscovery", isDirectory: true)
            .appendingPathComponent("manifests", isDirectory: true)
    }
}
