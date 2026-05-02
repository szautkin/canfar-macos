// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - find_images_with_packages (read)

/// Pure cache read: which images contain ALL the named packages.
/// No Skaha cost — answers from the coordinator's manifest cache.
/// When the query is empty, returns every image with a successful
/// cached manifest.
struct FindImagesWithPackagesTool: JSONReadTool {

    struct Args: Decodable, Sendable {
        var dpkg: [String]?
        var rpm: [String]?
        var apk: [String]?
        var python: [String]?
        var r: [String]?
        var osFamily: [String]?
        var osVersion: [String]?
    }

    struct Output: Encodable, Sendable {
        /// Image ids that match — pass any one verbatim to
        /// `launch_session` / `launch_headless_job` (`.image`).
        let imageIDs: [String]
        /// True when no constraints were supplied; in that case the
        /// result is every image with a successful cached manifest
        /// (failures aren't included — they have no manifest to
        /// match against).
        let unfiltered: Bool
        /// `imageIDs.count` for convenience.
        let count: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "find_images_with_packages",
        description: "Search the user's local image-content cache for images that contain ALL listed packages (intersection). Free — no Skaha jobs run. Returns image ids you can pass verbatim to launch_session / launch_headless_job. To populate the cache, call discover_image_packages first (or open the in-app discovery sheet). Empty query returns every image with a successful cached manifest.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "dpkg":      { "type": "array", "items": { "type": "string" } },
            "rpm":       { "type": "array", "items": { "type": "string" } },
            "apk":       { "type": "array", "items": { "type": "string" } },
            "python":    { "type": "array", "items": { "type": "string" } },
            "r":         { "type": "array", "items": { "type": "string" } },
            "osFamily":  { "type": "array", "items": { "type": "string" } },
            "osVersion": { "type": "array", "items": { "type": "string" } }
          },
          "additionalProperties": false
        }
        """#
    )

    let search: @Sendable (PackageQuery) async -> [String]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        var q = PackageQuery()
        q.dpkg        = Set(args.dpkg ?? [])
        q.rpm         = Set(args.rpm ?? [])
        q.apk         = Set(args.apk ?? [])
        q.python      = Set(args.python ?? [])
        q.r           = Set(args.r ?? [])
        q.osFamilies  = Set(args.osFamily ?? [])
        q.osVersions  = Set(args.osVersion ?? [])
        let ids = await search(q)
        return Output(imageIDs: ids, unfiltered: q.isEmpty, count: ids.count)
    }
}

// MARK: - discover_image_packages (write)

/// Schedule a probe job for one image. Cache-hit short-circuits
/// instantly; misses run a real headless job (visible in the
/// Background Jobs panel and cancellable via delete_session). Marked
/// .semanticWrite so it goes through the autonomy toggle alongside
/// launch_session — strip-confirm mode gates each probe explicitly,
/// auto-apply mode runs them as the agent calls.
struct DiscoverImagePackagesTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let image: String
        /// Default false. When true, skips the cache-hit short-circuit
        /// and runs a fresh probe even if a manifest already exists.
        var force: Bool?
    }

    struct Payload: Codable, Sendable {
        let image: String
        let force: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "discover_image_packages",
        description: "Run a probe job inside the named Skaha image to enumerate its installed packages (apt/rpm/apk + pip + conda + R) and cache the result. Cache-hit short-circuits with no Skaha cost. Cache-miss runs a small headless job (visible in the Background Jobs panel; delete_session to cancel). Default behaviour: skips probing if a manifest is already cached. Pass force=true to re-probe (e.g. after an image rebuild). Returns when the manifest is cached and queryable via find_images_with_packages.",
        schema: #"""
        {
          "type": "object",
          "required": ["image"],
          "properties": {
            "image": { "type": "string", "minLength": 1 },
            "force": { "type": "boolean" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let force = args.force ?? false
        let summary = force
            ? "Re-probe packages installed in '\(args.image)'"
            : "Discover packages installed in '\(args.image)'"
        return try ProposalPlan.encoding(
            kind: "discover_image_packages",
            summary: summary,
            payload: Payload(image: args.image, force: force)
        )
    }
}

/// Applier for `discover_image_packages`. Resolves the coordinator
/// lazily because it's auth-scoped (created in
/// `AppState.afterAuthenticated`, nil before login). Tools and
/// appliers register at app launch — long before auth — so a
/// captured coordinator reference would either be nil-fixed or
/// require re-registration after auth. The closure pattern mirrors
/// what the read tools do.
struct DiscoverImagePackagesApplier: ProposalApplier {
    let kind = "discover_image_packages"
    let resolveCoordinator: @Sendable () async -> ImageDiscoveryCoordinator?
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(
            DiscoverImagePackagesTool.Payload.self,
            from: proposal.payload
        )
        guard let coord = await resolveCoordinator() else {
            throw ProposalApplyError.backendError(
                "Image discovery requires authentication."
            )
        }
        do {
            if payload.force {
                _ = try await coord.rediscover(payload.image)
            } else {
                _ = try await coord.discover(payload.image)
            }
        } catch let err as ImageDiscoveryError {
            throw ProposalApplyError.backendError(err.displayMessage)
        } catch {
            throw ProposalApplyError.backendError(error.localizedDescription)
        }
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}
