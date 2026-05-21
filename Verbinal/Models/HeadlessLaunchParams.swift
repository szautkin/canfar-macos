// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Inputs for launching one or more replicas of a headless Skaha job.
///
/// Wire shape matches the canonical Python `canfar` client
/// (opencadc/canfar `models/session.py` `CreateRequest`):
///
///   * `cmd` is a single string the container runs.
///   * `args` is a single space-separated string (NOT an array) — the
///     server reads it via `getParameter("args")`.
///   * `env` is multi-valued: each `(key, value)` becomes a repeated
///     `env=KEY=VAL` form field.
///   * `replicas` is a *client-side* loop. The server doesn't know
///     about it; the client posts N times with `name-1, name-2, …`
///     and injects `REPLICA_ID` / `REPLICA_COUNT` per replica's env.
///
/// Image normalization (auto-prefix the registry host, auto-suffix
/// `:latest`) is the *caller's* responsibility — the in-app form
/// uses the registry picker, the MCP path uses pre-validated ids
/// returned by `list_session_images`. This struct is neutral.
struct HeadlessLaunchParams: Equatable {
    var name: String
    var image: String
    var cmd: String?
    /// Single whitespace-separated string. Skaha's server-side reads
    /// this as one parameter (`getParameter("args")`), then splits.
    var args: String?
    /// Ordered KV pairs. Insertion order is preserved on the wire.
    /// Empty dict = no extra env beyond the auto-injected REPLICA_*.
    var env: [(String, String)] = []
    var cores: Int?
    var ram: Int?
    var gpus: Int?
    /// Number of replica containers to spin up. ≥ 1; values < 1 are
    /// clamped. Each replica POSTs separately; failure of replica N
    /// leaves replicas 0..<N already running (best-effort partial
    /// success — matches the Python client; the caller decides how
    /// to surface partial state to the user).
    var replicas: Int = 1

    /// Pre-built `x-skaha-registry-auth` header value (base64 of
    /// `username:secret`). When set, `HeadlessService` attaches it
    /// to the launch POST so Skaha can pull from a private namespace
    /// without rejecting the job at submit time with HTTP 400 "No
    /// authentication provided for unknown or private image."
    ///
    /// Built by `ImageDiscoverySettingsService.currentAuthHeader()`
    /// reading the user-configured `(username, Keychain secret)`
    /// pair. `nil` when no credentials are configured — the launch
    /// proceeds without the header, which is fine for fully-public
    /// images and matches the historic behaviour for the in-app
    /// session launch path.
    var registryAuthHeader: String?

    static func == (lhs: HeadlessLaunchParams, rhs: HeadlessLaunchParams) -> Bool {
        lhs.name == rhs.name &&
        lhs.image == rhs.image &&
        lhs.cmd == rhs.cmd &&
        lhs.args == rhs.args &&
        lhs.env.elementsEqual(rhs.env, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
        lhs.cores == rhs.cores &&
        lhs.ram == rhs.ram &&
        lhs.gpus == rhs.gpus &&
        lhs.replicas == rhs.replicas &&
        lhs.registryAuthHeader == rhs.registryAuthHeader
    }
}

/// Errors specific to the headless-launch flow. Generic networking
/// failures still come through as `NetworkError`.
enum HeadlessLaunchError: Error, Equatable {
    /// Skaha returned 200 OK but the body was empty / not a session id.
    /// Should not happen in practice; safety net for unexpected server
    /// responses.
    case emptyResponse
    /// At least one replica was launched successfully but a later
    /// replica failed. `launchedIDs` are the live sessions; the user
    /// can still interact with them, the MCP client can `delete_session`
    /// to roll back if desired. `failedAtIndex` is 0-based.
    case partialReplicaFailure(launchedIDs: [String], failedAtIndex: Int, underlyingMessage: String)
}
