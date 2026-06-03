// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// User-configurable settings for the **AI Remote Compute** feature —
/// the `verbinal-execution` contributed-session image the agent
/// `run_code` tool drives.
///
/// Mirrors `ImageDiscoverySettings` (registry host + credentials + an
/// image) but for a different image and a separate keyspace/Keychain
/// entry, so the compute image can live in a different registry — or use
/// different Harbor credentials — than the inspector probe image.
///
/// The compute image is commonly **private** (e.g.
/// `images.canfar.net/private-test/verbinal-execution:…`), so Skaha
/// needs the `x-skaha-registry-auth` header to pull it when `run_code`
/// launches the session. The secret lives only in the Keychain;
/// `hasSecret` is the derived "set / not set" flag for the UI.
struct AIComputeSettings: Equatable, Sendable {

    /// Registry host the credentials below authenticate against, for
    /// pulling the AI compute image. Default `images.canfar.net`.
    var registryHost: String = "images.canfar.net"

    /// Username for the registry (for CANFAR Harbor, your CADC username).
    var username: String = ""

    /// True when a non-empty secret is stored in the Keychain for the
    /// current `(registryHost, username)` pair.
    var hasSecret: Bool = false

    /// The container image launched as a `contributed` interactive
    /// session for `run_code`. Empty disables `run_code`.
    var image: String = AIComputeSettings.defaultImage

    /// No built-in default: empty means "unset / `run_code` disabled",
    /// so an unset field can never silently launch the wrong container.
    static let defaultImage: String = ""

    /// True when an image is configured — i.e. `run_code` may launch.
    var isEnabled: Bool {
        !image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when nothing user-configured is present — drives the
    /// Settings "Reset" affordance.
    var isAllDefaults: Bool {
        username.isEmpty
            && !hasSecret
            && image == AIComputeSettings.defaultImage
            && (registryHost == "images.canfar.net" || registryHost.isEmpty)
    }
}
