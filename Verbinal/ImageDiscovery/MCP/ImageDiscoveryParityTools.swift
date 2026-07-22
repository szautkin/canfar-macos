// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Image-discovery parity tools — the discovery sheet's diagnostics that
/// `find_images_with_packages` / `discover_image_packages` didn't cover:
/// failure rows, probe logs/events, cached manifests, and clearing
/// failures. Capability closures are injected at wiring time.

// MARK: - list_probe_failures

/// The discovery sheet's failed rows: images whose last probe attempt
/// failed, with category and message.
struct ListProbeFailuresTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let failures: [Failure]

        struct Failure: Encodable, Sendable {
            let imageID: String
            let category: String
            let message: String
            let attemptedAtISO: String
            /// Skaha job id of the failed probe when one was launched —
            /// pass to `get_probe_logs` to diagnose.
            let jobID: String?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_probe_failures",
        description: "List images whose last package-discovery probe FAILED (the discovery sheet's error rows): image id, failure category (job_submit_failed / job_timed_out / manifest_fetch_failed / manifest_parse_failed / cancelled / unknown), message, attempt time, and — when a probe job was actually launched — its jobID for `get_probe_logs`. Clear with `clear_probe_failures` or retry with `discover_image_packages` (force).",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [Output.Failure]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        Output(failures: await snapshot())
    }
}

// MARK: - get_probe_logs

/// Container logs + Kubernetes events of a discovery probe job — the
/// sheet's "View logs" diagnostic.
struct GetProbeLogsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let jobID: String
    }

    struct Output: Encodable, Sendable {
        let jobID: String
        let logs: String
        let events: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_probe_logs",
        description: "Container logs and Kubernetes events for one package-discovery probe job (jobID from `list_probe_failures`) — the discovery sheet's \"View logs\" diagnostic. Use to find out why a probe failed inside the container.",
        schema: #"""
        {
          "type": "object",
          "required": ["jobID"],
          "properties": { "jobID": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    /// Returns (logs, events); throws typed failures.
    let fetch: @Sendable (String) async throws -> (logs: String, events: String)

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let result = try await fetch(args.jobID)
        return Output(jobID: args.jobID, logs: result.logs, events: result.events)
    }
}

// MARK: - get_image_manifest

/// Summary of one image's cached package manifest — the sheet's
/// manifest detail view, without the megabyte package dump.
struct GetImageManifestTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let image: String
    }

    struct Output: Encodable, Sendable {
        let imageID: String
        let capturedAtISO: String
        let contentHash: String
        let osFamily: String
        let osVersion: String
        let kernel: String
        let dpkgCount: Int
        let rpmCount: Int
        let apkCount: Int
        let pythonCount: Int
        let rCount: Int
        let condaEnvNames: [String]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_image_manifest",
        description: "Summary of one image's locally-cached package manifest (by full image id from `find_images_with_packages` / `list_session_images`): probe time, content hash, OS family/version, kernel, per-ecosystem package counts, and conda env names — the discovery sheet's manifest detail. Fails when the image has never been probed (run `discover_image_packages`). To search package CONTENTS use `find_images_with_packages`.",
        schema: #"""
        {
          "type": "object",
          "required": ["image"],
          "properties": { "image": { "type": "string", "description": "Full registry-qualified image id." } },
          "additionalProperties": false
        }
        """#
    )

    /// nil when the image has no cached successful manifest.
    let lookup: @Sendable (String) async -> Output?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard let output = await lookup(args.image) else {
            throw ToolFailureReason.unknownTarget(
                "no cached manifest for '\(args.image)' — probe it with discover_image_packages")
        }
        return output
    }
}

// MARK: - clear_probe_failures (destructive)

struct ClearProbeFailuresTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        /// Clear one image's failure record; omit to clear ALL failures.
        var image: String?
    }

    struct Payload: Codable, Sendable {
        let image: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_probe_failures",
        description: "Dismiss package-discovery failure records — the sheet's per-row \"Dismiss error\" (pass `image`) or header \"Clear all errors\" (omit it). Successful manifests are untouched; cleared images return to never-probed state. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "image": { "type": "string", "description": "One image id to clear; omit for all failures." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        try ProposalPlan.encoding(
            kind: "clear_probe_failures",
            summary: args.image.map { "Dismiss probe failure for \($0)" }
                ?? "Clear all probe failures",
            payload: Payload(image: args.image)
        )
    }
}

struct ClearProbeFailuresApplier: ProposalApplier {
    let kind = "clear_probe_failures"
    /// Resolves the coordinator at apply time (auth-scoped, nil pre-login).
    let resolveCoordinator: @Sendable () async -> ImageDiscoveryCoordinator?
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ClearProbeFailuresTool.Payload.self, from: proposal.payload)
        guard let coordinator = await resolveCoordinator() else {
            throw ProposalApplyError.backendError("Sign in to CADC first — discovery is auth-scoped")
        }
        if let image = payload.image {
            guard case .failure = await coordinator.outcome(for: image) else {
                throw ProposalApplyError.backendError("'\(image)' has no failure record")
            }
            try await coordinator.invalidate(imageID: image)
        } else {
            try await coordinator.clearFailures()
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
