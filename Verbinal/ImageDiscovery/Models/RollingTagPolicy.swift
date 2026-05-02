// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Detects "rolling" image tags whose content drifts in place
/// (e.g. `:latest`, `:dev`, `:nightly`) and applies a freshness
/// window so stale cache entries can be flagged in the UI even
/// though the image id hasn't changed.
///
/// Versioned tags at CADC (`:24.07`, `:1.1.2`) are effectively
/// immutable — their manifests never go stale on their own. Rolling
/// tags get a 24h window: anything older counts as stale and the
/// row badges with `clock.badge.exclamationmark` so the user knows
/// to rediscover.
enum RollingTagPolicy {

    /// 24-hour window. Anything published under a rolling tag and
    /// older than this is considered stale.
    static let stalenessWindow: TimeInterval = 24 * 60 * 60

    /// Tag suffixes that drift in place. Match is case-insensitive.
    /// Add to this set as new conventions appear in CADC's
    /// catalogue.
    private static let rollingSuffixes: Set<String> = [
        "latest", "dev", "nightly", "main", "edge", "staging", "unstable"
    ]

    /// `images.canfar.net/skaha/astroml:latest` → true
    /// `images.canfar.net/skaha/astroml:24.07` → false
    static func isRollingTag(_ imageID: String) -> Bool {
        guard let colon = imageID.lastIndex(of: ":") else { return false }
        let tag = imageID[imageID.index(after: colon)...]
            .lowercased()
        return rollingSuffixes.contains(String(tag))
    }

    /// Whether a cached manifest should be considered stale RIGHT
    /// NOW. Versioned-tag manifests are never stale by this policy.
    static func isStale(manifest: ImageManifest, now: Date = Date()) -> Bool {
        guard isRollingTag(manifest.imageID) else { return false }
        return now.timeIntervalSince(manifest.capturedAt) > stalenessWindow
    }

    /// "Discovered 3 days ago" / "Discovered 5 hours ago" — used in
    /// the row tooltip. Returns nil for fresh manifests so the
    /// caller can skip rendering.
    static func staleAgeLabel(for manifest: ImageManifest, now: Date = Date()) -> String? {
        guard isStale(manifest: manifest, now: now) else { return nil }
        let elapsed = now.timeIntervalSince(manifest.capturedAt)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        let phrase = formatter.string(from: elapsed) ?? "a while"
        return "Discovered \(phrase) ago — rediscover for fresh data"
    }
}
