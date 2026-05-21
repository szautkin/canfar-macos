// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// List Skaha container images the user is allowed to launch.
///
/// Closes the gap that caused agents to hand-type `image` strings into
/// `launch_session` and get back HTTP 400 ("unknown or private image")
/// from Skaha. The catalogue at `/skaha/v1/image` is authoritative —
/// each entry carries its full registry-qualified id and the session
/// types it supports.
///
/// Read-only; no auth required beyond the user being signed in (the
/// catalogue itself is gated by the Skaha bearer token, same as the
/// in-app launch form).
struct ListSessionImagesTool: JSONReadTool {
    // The Skaha image catalogue is small and quick to fetch; 30s
    // bounds the transport-stall failure mode the 2026-05-15 QA
    // report flagged for list_* tools.
    var toolTimeoutSeconds: TimeInterval { 30 }

    struct Args: Decodable, Sendable {
        /// Optional filter — keep only images whose `types` array
        /// contains this value. One of: "notebook", "desktop",
        /// "firefly", "carta", "contributed", "headless".
        let type: String?
    }

    struct Output: Encodable, Sendable {
        let images: [Entry]
        /// Static guidance about which `(cores, ram, gpus)` shapes
        /// schedule quickly on the shared CANFAR cluster vs which
        /// will queue. Closes the 2026-05-15 QA finding: "No
        /// metadata on cluster capacity — no way to query 'is
        /// 4c/8g currently fast or slow' before committing. I'd
        /// settle for a 'typical schedule time' hint in
        /// list_session_images." This is static, not real-time —
        /// agents should treat it as policy guidance, not
        /// telemetry. Real telemetry is queued for a future
        /// `get_service_health` extension.
        let schedulingGuidance: SchedulingGuidance

        struct Entry: Encodable, Sendable {
            /// Full registry-qualified image id, e.g.
            /// "images.canfar.net/skaha/astroml:24.07". Pass this
            /// verbatim as `launch_session.image` — the value is
            /// what Skaha expects, no trimming or rebuilding.
            let id: String
            /// Session types this image can run as. Most images
            /// support one type; multi-type entries (e.g. images
            /// that run as both `notebook` and `contributed`) are
            /// rare but legal.
            let types: [String]
        }

        struct SchedulingGuidance: Encodable, Sendable {
            /// One-line explainer the agent surfaces to humans
            /// when justifying its shape choice.
            let note: String
            /// Ordered fastest → slowest. Agents picking sizes
            /// should default to the first entry and only move
            /// down the list with an empirical justification
            /// (previous job OOMed, wallclocked out, etc.).
            let tiers: [Tier]

            struct Tier: Encodable, Sendable {
                let cores: Int
                let ram: Int
                let gpus: Int
                /// `"fast"` (<60s typical placement), `"warm"`
                /// (1–15 min), `"slow"` (15+ min on a quiet day,
                /// hours when the cluster is busy).
                let tier: String
                /// Human-readable note: when to use, what the
                /// trade-off is.
                let advice: String
            }
        }

        /// Canonical static guidance. Matches the tier semantics
        /// baked into `launch_headless_job`'s default-down logic
        /// (1c/1g/0gpu is the forced default; anything bigger
        /// surfaces a scheduling warning).
        static let canonicalSchedulingGuidance = SchedulingGuidance(
            note: "Job placement on the shared CANFAR cluster scales inversely with the resource ask. Default to 1 CPU / 1 GB RAM / 0 GPU for smoke tests and iterative work; ask for more only after a 1c/1g run actually OOMed or wallclocked out. Tiers below are static policy guidance derived from 2026-05 cluster-pressure observations, not real-time telemetry.",
            tiers: [
                SchedulingGuidance.Tier(
                    cores: 1, ram: 1, gpus: 0, tier: "fast",
                    advice: "Smallest schedulable shape. Almost always lands on a warm node in <60s. Default for launch_headless_job — start here unless you have a specific reason not to."
                ),
                SchedulingGuidance.Tier(
                    cores: 2, ram: 8, gpus: 0, tier: "warm",
                    advice: "Skaha's server-side default when shape is omitted. Routinely sits in Pending 15+ min under shared-cluster pressure. Use only when a 1c/1g run hit memory or wallclock limits."
                ),
                SchedulingGuidance.Tier(
                    cores: 4, ram: 16, gpus: 0, tier: "slow",
                    advice: "Production-only. Expect hours of queue time during peak hours. Verify the workload truly needs this shape with a 1c/1g profile run first."
                ),
                SchedulingGuidance.Tier(
                    cores: 1, ram: 1, gpus: 1, tier: "slow",
                    advice: "GPU asks queue indefinitely on most images. Only use with GPU-typed images (check the image's `capabilities` for `gpu`) AND for genuinely CUDA-bound workloads."
                ),
            ]
        )
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_session_images",
        description: "List Skaha container images this user is allowed to launch. Returns full registry-qualified ids — pass one verbatim as `launch_session.image`. Optional `type` filter (notebook/desktop/firefly/carta/contributed/headless). Hand-typed image strings WILL fail with HTTP 400; always pick from this list. Output also carries a `schedulingGuidance` block: per-shape tier hints (fast/warm/slow) you should consult BEFORE picking `cores`/`ram`/`gpus` on `launch_headless_job` or `launch_session`. 1c/1g/0gpu is the fastest schedulable shape and the recommended default; anything bigger frequently queues for 15+ min on the shared cluster.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "type": { "type": "string", "enum": ["notebook", "desktop", "firefly", "carta", "contributed", "headless"] }
          },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable () async throws -> [(id: String, types: [String])]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let raw: [(id: String, types: [String])]
        do {
            raw = try await fetch()
        } catch {
            throw ToolFailureReason.backendError("Skaha image catalogue: \(error.localizedDescription)")
        }
        let filter = args.type
        let entries: [Output.Entry] = raw.compactMap { entry in
            if let filter, !entry.types.contains(filter) { return nil }
            return Output.Entry(id: entry.id, types: entry.types)
        }
        return Output(
            images: entries,
            schedulingGuidance: Output.canonicalSchedulingGuidance
        )
    }
}
