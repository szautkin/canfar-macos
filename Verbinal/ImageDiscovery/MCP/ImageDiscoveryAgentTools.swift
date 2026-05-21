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
        var capabilities: [String]?
        /// Session-type filter applied to BOTH `imageIDs` (the
        /// match set) and `candidatesToProbe` (the
        /// unprobed-but-might-fit set). Useful when the caller is
        /// driving toward `launch_headless_job` — passing
        /// `type: "headless"` narrows everything to images that
        /// can actually run as headless batch jobs and excludes
        /// notebook/desktop/carta entries that would be
        /// irrelevant for that launch path.
        var type: String?
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
        /// Visibility into how much of the catalogue the local cache
        /// has actually probed. When `discovered` < `total`, the
        /// `matching` count can only speak about the images that
        /// have been seen — silent gaps may exist in the unprobed
        /// majority.
        let coverage: Coverage
        /// Catalogue images that haven't been probed yet AND
        /// match the optional `type` filter. The agent's next
        /// step when `imageIDs` is empty: pick one of these and
        /// call `discover_image_packages(image: ...)`. Capped at
        /// 10 entries to keep responses bounded — that's enough
        /// for the agent to make an informed pick without
        /// flooding the conversation. Empty when the catalogue
        /// is fully probed for the relevant type.
        let candidatesToProbe: [String]
        /// Every image the user has already probed, regardless
        /// of whether it matched the current query. Lets the
        /// agent reason about "what's discovered at all?"
        /// without a second call (e.g. to suggest re-discovery
        /// of a stale manifest, or to summarise the user's
        /// existing knowledge). Filtered by `type` when the
        /// caller asked for one.
        let allDiscovered: [String]
        /// Ranked near-miss images when the strict intersection
        /// (`imageIDs`) is empty AND the query was non-empty.
        /// Populated from manifests that satisfied ≥50% of the
        /// caller's constraints, sorted by score desc, capped at
        /// 5 entries. Empty when `imageIDs` is non-empty (no
        /// need — the agent already has actionable hits) or
        /// when the query was empty (every manifest trivially
        /// scores 1.0).
        ///
        /// Closes the 2026-05-15 QA finding: asking for
        /// `[astropy, scipy, astroquery, numpy, fitsio, python3]`
        /// returned 0 strict matches because no single image had
        /// all six — even though four had three or more. The
        /// agent had no actionable next step beyond manually
        /// loosening the query; `partialMatches` surfaces those
        /// near-miss images directly.
        let partialMatches: [PartialMatchOut]

        struct Coverage: Encodable, Sendable {
            let total: Int
            let discovered: Int
            let matching: Int
        }

        struct PartialMatchOut: Encodable, Sendable {
            let imageID: String
            /// Fraction of constraints satisfied, 0.0–1.0.
            let score: Double
            /// Constraint identifiers the manifest didn't satisfy,
            /// e.g. `"python:fitsio"`, `"capability:gpu"`. Use
            /// these to decide between "install the missing piece
            /// with pip" and "pick a different image."
            let missing: [String]
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "find_images_with_packages",
        description: "Search the user's local image-content cache for images that contain ALL listed packages / capabilities (intersection). Free — no Skaha jobs run. `capabilities` filters on behavioural flags the probe detects beyond raw package names — `fitsio`, `photutils-iterative-psf`, `gpu`, `python3`, `conda`, `rscript`. Optional `type` (notebook/desktop/carta/firefly/contributed/headless) narrows to images launchable as that session type. Returns five complementary fields: (1) `imageIDs` — strict-match hits you can launch right now; (2) `candidatesToProbe` — up to 10 unprobed catalogue images that fit the `type` filter, your next-step shortlist when matches are empty; (3) `allDiscovered` — every image the user has probed (matched or not) so you can see what knowledge already exists; (4) `coverage` — how many of the catalogue have been probed at all; (5) `partialMatches` — ranked near-miss images with a `score` (0.0–1.0 fraction of constraints satisfied) and `missing` list, populated ONLY when `imageIDs` is empty AND you supplied filters. Use partialMatches when over-specifying drops you to zero hits: an image with 5 of 6 packages plus pip-installable missing is often the right pick. When `imageIDs` is empty but `candidatesToProbe` is non-empty, the answer is \"unknown, but here's what to probe next\" — call `discover_image_packages` on one of them.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "dpkg":         { "type": "array", "items": { "type": "string" } },
            "rpm":          { "type": "array", "items": { "type": "string" } },
            "apk":          { "type": "array", "items": { "type": "string" } },
            "python":       { "type": "array", "items": { "type": "string" } },
            "r":            { "type": "array", "items": { "type": "string" } },
            "osFamily":     { "type": "array", "items": { "type": "string" } },
            "osVersion":    { "type": "array", "items": { "type": "string" } },
            "capabilities": { "type": "array", "items": { "type": "string", "enum": ["fitsio", "photutils-iterative-psf", "gpu", "python3", "conda", "rscript"] } },
            "type":         { "type": "string", "enum": ["notebook", "desktop", "carta", "firefly", "contributed", "headless"] }
          },
          "additionalProperties": false
        }
        """#
    )

    let search: @Sendable (PackageQuery) async -> [String]
    /// Snapshot of the live Skaha image catalogue. The tool
    /// needs this to compute `candidatesToProbe` (catalogue minus
    /// probed) and to honor the `type` filter without pulling
    /// types from probed manifests (which the inspector path
    /// doesn't populate). Returns `[(id, types)]` so the type
    /// filter can run client-side. Empty on auth failure.
    let catalogue: @Sendable () async -> [(id: String, types: [String])]
    /// Image IDs already probed (any non-stub manifest cached).
    let discoveredIDs: @Sendable () async -> [String]
    /// Partial-match scoring used when the strict AND-match is
    /// empty. Returns the top images ranked by fraction of
    /// constraints satisfied, with the unmet constraint list per
    /// entry. `minScore` and `limit` are tool defaults
    /// (0.5 / 5) — the wireup layer is free to override for
    /// other surfaces.
    let searchPartial: @Sendable (PackageQuery, _ minScore: Double, _ limit: Int) async -> [PartialMatch]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        var q = PackageQuery()
        q.dpkg         = Set(args.dpkg ?? [])
        q.rpm          = Set(args.rpm ?? [])
        q.apk          = Set(args.apk ?? [])
        q.python       = Set(args.python ?? [])
        q.r            = Set(args.r ?? [])
        q.osFamilies   = Set(args.osFamily ?? [])
        q.osVersions   = Set(args.osVersion ?? [])
        q.capabilities = Set(args.capabilities ?? [])

        // Snapshot the query as an immutable value before the
        // concurrent fan-out. The `async let`s capture the
        // closure-argument value and Swift's strict-concurrency
        // pass treats a captured `var` as racy even though the
        // construction above is sequential.
        let query = q
        async let matches = search(query)
        async let cat = catalogue()
        async let discovered = discoveredIDs()
        let matchedIDs = await matches
        let catRows = await cat
        let allDiscovered = Set(await discovered)

        // Catalogue projection — apply the type filter once,
        // reuse the result for both candidate-list and total
        // counts.
        let typeFilter = args.type?.lowercased()
        let scopedCatalogueIDs: [String] = catRows.compactMap { row in
            if let typeFilter,
               !row.types.map({ $0.lowercased() }).contains(typeFilter) {
                return nil
            }
            return row.id
        }
        let scopedCatalogueSet = Set(scopedCatalogueIDs)

        // Match set respects the type filter too — agents that
        // ask for `type: "headless"` don't want a notebook match
        // even if its packages line up.
        let scopedMatches = matchedIDs.filter { typeFilter == nil || scopedCatalogueSet.contains($0) }

        // Partial-match scoring runs only when the strict
        // intersection produced nothing AND the user actually
        // supplied constraints. Skipping it for non-empty hits
        // keeps the response shape clean — agents with actionable
        // matches don't want a parallel ranked list cluttering
        // their reasoning. Skipping it for empty queries avoids
        // returning every manifest with a meaningless score of
        // 1.0.
        let partialMatchesOut: [Output.PartialMatchOut]
        if scopedMatches.isEmpty && !query.isEmpty {
            let scored = await searchPartial(query, 0.5, 5)
            // Apply the type filter post-scoring; the score is
            // independent of session-type so we just drop
            // off-type rows after ranking.
            let scopedScored = scored.filter {
                typeFilter == nil || scopedCatalogueSet.contains($0.imageID)
            }
            partialMatchesOut = scopedScored.map {
                Output.PartialMatchOut(
                    imageID: $0.imageID,
                    score: $0.score,
                    missing: $0.missing
                )
            }
        } else {
            partialMatchesOut = []
        }

        // `candidatesToProbe` = catalogue items that fit the
        // type filter, aren't already probed, and we haven't
        // already matched. Sorted alphabetically for stable
        // ordering across calls (otherwise the cap below might
        // hand back a different subset turn-to-turn and confuse
        // an agent comparing responses).
        let probedSetForType = scopedCatalogueSet.intersection(allDiscovered)
        let candidatesAll = scopedCatalogueIDs
            .filter { !allDiscovered.contains($0) && !scopedMatches.contains($0) }
            .sorted()
        let candidates = Array(candidatesAll.prefix(10))

        // `allDiscovered` (output) — every probed image, type-
        // filtered when applicable. Lets the agent see "I've
        // probed X but Y images haven't matched my query" in
        // one response.
        let allDiscoveredScoped: [String]
        if typeFilter == nil {
            allDiscoveredScoped = allDiscovered.sorted()
        } else {
            allDiscoveredScoped = probedSetForType.sorted()
        }

        // Coverage counts the scoped universe when a type
        // filter is in play, so "discovered 2 of 8 headless" is
        // honest rather than "discovered 18 of 220 catalogue".
        let coverageTotal: Int
        let coverageDiscovered: Int
        if typeFilter == nil {
            coverageTotal = catRows.count
            coverageDiscovered = allDiscovered.count
        } else {
            coverageTotal = scopedCatalogueSet.count
            coverageDiscovered = probedSetForType.count
        }

        return Output(
            imageIDs: scopedMatches,
            unfiltered: query.isEmpty,
            count: scopedMatches.count,
            coverage: .init(
                total: coverageTotal,
                discovered: coverageDiscovered,
                matching: scopedMatches.count
            ),
            candidatesToProbe: candidates,
            allDiscovered: allDiscoveredScoped,
            partialMatches: partialMatchesOut
        )
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
        description: "Run a probe job to enumerate the named image's installed packages (apt/rpm/apk + pip + conda + R) and cache the result. Cache-hit short-circuits with no Skaha cost. Routing is automatic from the image's `types`: images that include `headless` run an in-target probe (the script runs inside the target image itself); all other types (notebook/desktop/carta/firefly/contributed) launch a known-good headless host (`terminal:1.1.2` by default) that introspects the target via syft against the registry — the target image is never executed. Cache-miss runs one small Skaha job (visible in the Background Jobs panel; delete_session to cancel). Skaha can hit a K8s `jobs.batch not found` race after submit; the coordinator retries with exponential backoff (~25s total budget) before failing with a structured message. Pass force=true to bypass cache for a known-fresh manifest (e.g. after an image rebuild). You DO NOT need force=true to retry after a transient probe failure — the coordinator auto-invalidates `probeNotes`-tagged stub manifests on the next call, so a plain re-invocation re-runs the probe. Returns when the manifest is cached and queryable via find_images_with_packages.",
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
