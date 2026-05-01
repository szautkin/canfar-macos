// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Streaming events the coordinator emits for batch discovery. The
/// UI consumes these via
/// `for await event in coordinator.discoverAll(ids)` and updates the
/// matching-images right pane progressively as each result lands.
///
/// Cache hits yield `.completed` immediately; misses go through
/// `.started` → polling tick(s) → `.completed` or `.failed`. That
/// flow is what gives the user "first manifest visible in seconds,
/// not after the whole batch finishes" UX.
enum DiscoveryEvent: Sendable, Equatable {
    /// Probe job submitted; cache miss is now in flight.
    case started(imageID: String)
    /// Manifest available — either from cache or freshly probed.
    case completed(imageID: String, manifest: ImageManifest)
    /// Discovery failed for this image; the cache stores the
    /// failure outcome so the UI can render "tried at X, failed".
    case failed(imageID: String, error: ImageDiscoveryError)
}
