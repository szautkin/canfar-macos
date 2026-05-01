// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Typed failures from the discovery pipeline. The coordinator throws
/// these; the cache stores a downcast `LastOutcome.FailureCategory`
/// + message because the typed associated values don't all Codable
/// trivially and the cache only needs enough to render a UI status.
enum ImageDiscoveryError: Error, Equatable, Sendable {
    /// Couldn't enqueue the headless probe job. Usually a Skaha
    /// 4xx/5xx (private image, registry-auth missing, quota).
    case jobSubmitFailed(message: String)
    /// Probe ran longer than the coordinator's timeout
    /// (default 5 min). Job may still be running on Skaha;
    /// caller can resubmit or wait via `list_headless_jobs`.
    case jobTimedOut
    /// Skaha said the job succeeded but the manifest isn't in
    /// VOSpace at the expected path.
    case manifestFetchFailed(message: String)
    /// Manifest fetched but parsed as malformed / wrong schema.
    case manifestParseFailed(detail: String)
    /// Caller cancelled (e.g. UI dismissed).
    case cancelled
    /// Anything else, with a message.
    case unknown(message: String)

    /// String the UI shows the user. Short, no internals.
    var displayMessage: String {
        switch self {
        case .jobSubmitFailed(let m): return "Probe submit failed: \(m)"
        case .jobTimedOut: return "Probe timed out"
        case .manifestFetchFailed(let m): return "Manifest fetch failed: \(m)"
        case .manifestParseFailed(let d): return "Manifest parse failed: \(d)"
        case .cancelled: return "Discovery cancelled"
        case .unknown(let m): return m
        }
    }

    /// Project this error to the cache's stable string category.
    var cacheCategory: LastOutcome.FailureCategory {
        switch self {
        case .jobSubmitFailed: return .jobSubmitFailed
        case .jobTimedOut: return .jobTimedOut
        case .manifestFetchFailed: return .manifestFetchFailed
        case .manifestParseFailed: return .manifestParseFailed
        case .cancelled: return .cancelled
        case .unknown: return .unknown
        }
    }
}
