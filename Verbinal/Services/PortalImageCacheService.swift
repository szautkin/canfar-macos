// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

// MARK: - Model

/// Disk-persistable snapshot of the Skaha API image/context/repo payloads.
/// Keyed by `username` so cached data from one user is never shown to another.
struct PortalImageCache: Codable {
    var username: String
    var images: [RawImage]
    var context: SessionContext?
    var repositories: [String]
    var fetchedAt: Date
}

// MARK: - Service

/// Stale-while-revalidate disk cache for Skaha image / context / repository payloads.
/// Returns cached data instantly and lets the caller decide whether to kick off a
/// background refresh. Cache file lives at
/// `~/Library/Application Support/Verbinal/portal_image_cache.json`.
///
/// `@MainActor` isolated — SwiftUI views observe `cache` and `isFetching`.
/// Cleared on logout; settings (`PortalSettingsService`) are per-user and survive.
@Observable
@MainActor
final class PortalImageCacheService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PortalImageCache")
    private let persistence: DiskPersistence<PortalImageCache>
    private let cacheMaxAge: TimeInterval

    private(set) var cache: PortalImageCache?
    var isFetching = false
    /// Tracks the currently in-flight fetchFresh task so `clear()` can cancel it.
    private var activeFetchTask: Task<PortalImageCache, Error>?

    init(fileName: String = "portal_image_cache.json",
         cacheMaxAge: TimeInterval = 60 * 60 * 24) {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.cacheMaxAge = cacheMaxAge
        self.cache = persistence.read()
    }

    var isStale: Bool {
        guard let cache else { return true }
        return Date().timeIntervalSince(cache.fetchedAt) > cacheMaxAge
    }

    var cacheTimestamp: Date? { cache?.fetchedAt }

    /// Return cached data if it belongs to `username`, else fetch fresh.
    /// Returns `(cache, wasCached)` so the caller can decide on a background refresh.
    func loadOrFetch(
        username: String,
        imageService: ImageService
    ) async throws -> (cache: PortalImageCache, wasCached: Bool) {
        if let existing = cache, existing.username == username {
            return (existing, true)
        }
        let fresh = try await fetchFresh(username: username, imageService: imageService)
        return (fresh, false)
    }

    /// Force a fresh network fetch and rewrite the cache.
    /// Cancellable via `clear()` — if the user logs out mid-fetch, the task is
    /// cancelled and the in-flight response is discarded without writing to disk.
    @discardableResult
    func fetchFresh(
        username: String,
        imageService: ImageService
    ) async throws -> PortalImageCache {
        activeFetchTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            isFetching = true
            defer { isFetching = false }

            async let rawImagesTask = imageService.getImages()
            async let contextTask = imageService.getContext()
            async let reposTask = imageService.getRepositories()

            let rawImages = try await rawImagesTask
            let context = try? await contextTask
            let repos = (try? await reposTask) ?? []

            try Task.checkCancellation()

            let newCache = PortalImageCache(
                username: username,
                images: rawImages,
                context: context,
                repositories: repos,
                fetchedAt: Date()
            )
            self.cache = newCache
            self.persistence.write(newCache)
            // Username is institutional PII — keep redacted in logs.
            // Image count is safe to surface for diagnostics.
            Self.logger.info("Fetched \(rawImages.count) images for \(username, privacy: .private)")
            return newCache
        }
        activeFetchTask = task
        return try await task.value
    }

    /// Drop cached data and remove the file (called on logout / user change).
    /// Also cancels any in-flight `fetchFresh` so it cannot repopulate stale data.
    func clear() {
        activeFetchTask?.cancel()
        activeFetchTask = nil
        cache = nil
        persistence.delete()
    }
}
