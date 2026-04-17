// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Addon-side runtime. Every addon creates a single `AddonBeacon` in its app
/// entry point (e.g. inside `@main struct VerbinalPiApp`), hands it the static
/// manifest baked into `Contents/Resources/VerbinalAddon.plist`, and observes
/// incoming activation payloads via `activations`.
///
/// The beacon deliberately has no side effects on launch. It is a pure
/// coordinator: holding the manifest in memory for any host-initiated RPC that
/// could come later, and routing URL activations into an `AsyncStream` the
/// addon's SwiftUI root view can drain.
@MainActor
public final class AddonBeacon {

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "AddonBeacon")

    public let manifest: AddonManifest

    private let continuation: AsyncStream<AddonActivationContext>.Continuation
    public let activations: AsyncStream<AddonActivationContext>

    public init(manifest: AddonManifest) {
        self.manifest = manifest
        var tempContinuation: AsyncStream<AddonActivationContext>.Continuation!
        self.activations = AsyncStream<AddonActivationContext> { cont in
            tempContinuation = cont
        }
        self.continuation = tempContinuation
        Self.logger.info("AddonBeacon live: \(manifest.addonID, privacy: .public) v\(manifest.version, privacy: .public)")
    }

    /// Call from `AppDelegate.application(_:open:)` or equivalent SwiftUI
    /// `.onOpenURL(_:)` handler. Decodes the `ctx` query parameter and yields
    /// the decoded context onto `activations`.
    ///
    /// Unknown URLs (missing host, missing `ctx`, non-matching scheme) are
    /// logged at `.warning` and dropped — never crashes.
    public func handleIncomingURL(_ url: URL) {
        guard url.scheme == manifest.urlScheme else {
            Self.logger.warning("Ignoring URL with wrong scheme: \(url.absoluteString, privacy: .public)")
            return
        }
        guard url.host == "activate" else {
            Self.logger.warning("Ignoring URL with unsupported host: \(url.absoluteString, privacy: .public)")
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let ctxValue = components?.queryItems?.first(where: { $0.name == "ctx" })?.value else {
            // No payload → treat as "launch empty".
            continuation.yield(.launchEmpty)
            return
        }
        do {
            let context = try AddonActivationContext.decode(from: ctxValue)
            continuation.yield(context)
        } catch {
            Self.logger.error("Activation decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// End-of-process cleanup. SwiftUI apps rarely need to call this —
    /// the stream naturally ends when the app terminates.
    public func finish() {
        continuation.finish()
    }
}
