// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Persistence + query surface for image manifests. Behind a
/// protocol so the v1 file-per-image JSON store can be swapped for
/// a SQLite/GRDB-backed implementation later without touching the
/// coordinator or the UI.
///
/// All methods are async — the v1 conformance is an actor and
/// serializes filesystem IO behind it. The protocol documents the
/// contract; `JSONManifestStore` is the conformance.
protocol ManifestStore: Sendable {

    /// What does the cache currently know about this image? `nil`
    /// when never attempted; `.success(manifest)` when probed and
    /// parsed; `.failure(...)` when the last attempt failed (so the
    /// UI can show "tried Tuesday, failed: …" without re-running).
    func outcome(for imageID: String) async -> LastOutcome?

    /// Persist a successful manifest, replacing any prior outcome
    /// for the same image id.
    func setManifest(_ manifest: ImageManifest) async throws

    /// Persist a failure outcome with the timestamp of the attempt.
    /// Replaces any prior outcome.
    func setFailure(
        imageID: String,
        category: LastOutcome.FailureCategory,
        message: String,
        attemptedAt: Date
    ) async throws

    /// Drop a single image's record. Used by per-image "Rediscover"
    /// (Phase 5).
    func invalidate(imageID: String) async throws

    /// Drop everything. Used by Settings ▸ "Clear discovery cache".
    func clear() async throws

    /// Image ids whose manifests satisfy `query`. When `query` is
    /// empty, returns every image id with a *successful* outcome
    /// (failures are excluded from search results — they have no
    /// manifest to match against).
    ///
    /// Result order is sorted by image id for stable UI rendering.
    func search(_ query: PackageQuery) async -> [String]

    /// Every image id the cache has any record of (success or
    /// failure). The UI uses this to render rows for known images
    /// and decide which ones still need a discovery run.
    func knownImages() async -> [String]

    /// Distinct package names across all *successful* manifests,
    /// grouped by source. Drives the LEFT pane of the discovery
    /// sheet so users only see real choices, not phantom packages
    /// from never-discovered images.
    func allPackages() async -> AllPackages

    /// Number of records currently held. Tests use this; the
    /// settings UI uses it to confirm "Clear cache" before wiping.
    func count() async -> Int
}
