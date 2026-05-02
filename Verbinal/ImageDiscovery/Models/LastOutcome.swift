// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the cache last knew about a given image: a successful
/// manifest, or a typed failure with the timestamp of the attempt.
///
/// Distinct from `ImageManifest?` because "we tried 2 days ago and
/// it failed" is different UX from "we never tried" — both look
/// like `nil` if we collapsed them. The UI needs to show "Failed
/// (2d ago) — retry?" vs "Discover packages" vs the actual manifest.
///
/// `success(_:)` carries the parsed manifest. `failure(_:_:)` carries
/// a stringified failure category (so `LastOutcome` stays Codable
/// without bringing the typed error along — the typed error is for
/// in-flight handling; the cache stores enough to render an honest
/// status row).
enum LastOutcome: Codable, Equatable, Sendable {
    case success(ImageManifest)
    case failure(
        imageID: String,
        category: FailureCategory,
        message: String,
        attemptedAt: Date,
        /// Skaha session id of the probe job that failed, when the
        /// failure happened *after* a job was successfully launched.
        /// `nil` for failures earlier in the pipeline (probe-script
        /// upload, mkdir). Lets the UI offer "View logs" /
        /// "View events" so the user can diagnose the underlying
        /// container error.
        jobID: String?
    )

    /// Stable string identifiers so the JSON on disk doesn't depend on
    /// Swift enum case ordering.
    enum FailureCategory: String, Codable, Sendable, CaseIterable {
        /// Skaha rejected the launch (HTTP 4xx/5xx, auth, etc.) before
        /// the probe could run.
        case jobSubmitFailed = "job_submit_failed"
        /// Probe job ran but never reached terminal state inside our
        /// timeout (default 5 min).
        case jobTimedOut = "job_timed_out"
        /// Probe job reached terminal state but we couldn't fetch the
        /// manifest from VOSpace.
        case manifestFetchFailed = "manifest_fetch_failed"
        /// Manifest fetched but parsed as malformed / wrong schema.
        case manifestParseFailed = "manifest_parse_failed"
        /// User or coordinator cancelled.
        case cancelled = "cancelled"
        /// Anything else.
        case unknown = "unknown"
    }

    var imageID: String {
        switch self {
        case .success(let m): return m.imageID
        case .failure(let id, _, _, _, _): return id
        }
    }

    var attemptedAt: Date {
        switch self {
        case .success(let m): return m.capturedAt
        case .failure(_, _, _, let date, _): return date
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
