// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// User-configurable defaults for the Image Discovery feature.
///
/// Three knobs:
///
/// 1. **`registryHost`** — the registry hostname the credentials below
///    authenticate against. Default `images.canfar.net`. Changing this
///    is useful when you have an inspector image on Docker Hub, Quay,
///    GHCR, etc.
/// 2. **`username` + Keychain secret** — Harbor / registry credentials
///    used to mint the `x-skaha-registry-auth` header on probe jobs.
///    Without these, Skaha rejects pulls from private namespaces
///    (`canucs/`, project-specific `cadc/`, anything not flagged as
///    Harbor-public) with HTTP 400 at job-submit time.
/// 3. **`inspectorImage`** — the container image used as the *host*
///    for inspector-mode probing. Must be headless-launchable and ship
///    bash + python3 + curl/wget. See `docs/inspector-image.md` for
///    full build requirements.
///
/// The secret itself never lives in this struct — only in the
/// Keychain. `hasSecret` is a derived flag the UI uses to render the
/// "set" vs "not set" state without round-tripping the secret value.
struct ImageDiscoverySettings: Equatable, Sendable {

    /// Registry host the credentials authenticate against, e.g.
    /// `"images.canfar.net"`. Used by Skaha's
    /// `x-skaha-registry-auth` header logic. Empty string treated
    /// the same as the default — `currentAuthHeader()` ignores
    /// auth when host is missing.
    var registryHost: String = "images.canfar.net"

    /// Username for the registry. For CANFAR Harbor, your CADC
    /// username (e.g. `szautkin`); for other registries the
    /// account-specific value.
    var username: String = ""

    /// True when a non-empty secret is currently stored in the
    /// Keychain for this `(registryHost, username)` pair. The
    /// secret itself is never read into this struct — the UI
    /// reflects "set" or "not set", and the auth-header builder
    /// reads the secret on-demand at submit time.
    var hasSecret: Bool = false

    /// Container image used as the inspector host. Must be
    /// headless-launchable, contain bash + python3 + curl/wget,
    /// and currently be pullable for the user's Skaha account.
    /// See `docs/inspector-image.md`.
    var inspectorImage: String = ImageDiscoverySettings.defaultInspectorImage

    /// Built-in default — the historical inspector image. Verbinal
    /// surfaces this as the placeholder so users can revert by
    /// clearing the field.
    static let defaultInspectorImage: String = "images.canfar.net/skaha/terminal:1.1.2"

    /// True when no user-configured value is meaningfully present:
    /// empty username, no secret, and the inspector image still
    /// matches the built-in default. The Settings UI uses this to
    /// decide whether to show a "Reset" affordance.
    var isAllDefaults: Bool {
        username.isEmpty
            && !hasSecret
            && inspectorImage == ImageDiscoverySettings.defaultInspectorImage
            && (registryHost == "images.canfar.net" || registryHost.isEmpty)
    }
}
