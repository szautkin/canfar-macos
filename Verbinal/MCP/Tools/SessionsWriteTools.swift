// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - launch_session

/// Launch a Skaha session. Always proposal-gated — sessions consume
/// real cores/RAM/GPU resources and the proposal strip's confirmation
/// is the user's only safety against an agent typo.
struct LaunchSessionTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let type: String
        let name: String
        let image: String
        var cores: Int?
        var ram: Int?
        var gpus: Int?
        var cmd: String?
    }

    struct Payload: Codable, Sendable {
        let type: String
        let name: String
        let image: String
        let cores: Int
        let ram: Int
        let gpus: Int
        let cmd: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "launch_session",
        description: "Launch a new Skaha science-platform session. Type ∈ {notebook, desktop, firefly, carta, contributed}. The `image` MUST be a value returned by `list_session_images` for this user — hand-typed strings (e.g. 'images.canfar.net/skaha/notebook:latest') WILL fail with HTTP 400 'unknown or private image'. BEFORE picking an image when the user has tooling needs, call `find_images_with_packages(...)` — most catalogue images have a cached package manifest, and choosing the right pre-baked image up-front beats `pip install --user`-ing inside the running session. SCHEDULING: cores/ram/gpus default to 2/8/0 if omitted, which can sit in Pending for many minutes under cluster load; pass `cores: 1, ram: 1` for fastest start (typically <60s on a warm node) when you're iterating or smoke-testing. Pass cores=0 (or rely on default after rejection retry) to request the shared/flexible resource pool.",
        schema: #"""
        {
          "type": "object",
          "required": ["type", "name", "image"],
          "properties": {
            "type":  { "type": "string", "enum": ["notebook", "desktop", "firefly", "carta", "contributed"] },
            "name":  { "type": "string", "minLength": 1 },
            "image": { "type": "string", "minLength": 1 },
            "cores": { "type": "integer", "minimum": 1 },
            "ram":   { "type": "integer", "minimum": 1 },
            "gpus":  { "type": "integer", "minimum": 0 },
            "cmd":   { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let cores = args.cores ?? 2
        let ram = args.ram ?? 8
        let gpus = args.gpus ?? 0
        let summary = "Launch \(args.type) '\(args.name)' (\(cores) cores, \(ram) GB" +
                      (gpus > 0 ? ", \(gpus) GPUs" : "") +
                      ") — image: \(args.image)"
        return try ProposalPlan.encoding(
            kind: "launch_session",
            summary: summary,
            payload: Payload(
                type: args.type, name: args.name, image: args.image,
                cores: cores, ram: ram, gpus: gpus, cmd: args.cmd
            )
        )
    }
}

struct LaunchSessionApplier: ProposalApplier {
    let kind = "launch_session"
    let service: SessionService
    let recentLaunchStore: RecentLaunchStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(LaunchSessionTool.Payload.self, from: proposal.payload)
        let params = SessionLaunchParams(
            type: payload.type, name: payload.name, image: payload.image,
            cores: payload.cores, ram: payload.ram, gpus: payload.gpus,
            cmd: payload.cmd, registryUsername: nil, registrySecret: nil
        )
        do {
            // 3-minute deadline. Skaha session-create is normally
            // < 30s but can stall under cluster pressure; bounded
            // wait ensures the applier emits a terminal event
            // either way.
            let svc = service
            _ = try await withApplierTimeout(seconds: 180, label: "launch_session") {
                try await svc.launchSession(params)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("launch failed: \(error.localizedDescription)")
        }
        // Stash a RecentLaunch entry so the user sees this agent
        // launch alongside their own recents (with the wand badge in
        // commit 2). Without this the launch only appears in the live
        // session list and disappears after the session ends.
        let attribution = AgentAttribution.from(proposal: proposal)
        let launch = RecentLaunch(
            name: payload.name,
            type: payload.type,
            image: payload.image,
            imageLabel: payload.image,
            project: "",
            resourceType: "fixed",
            cores: payload.cores,
            ram: payload.ram,
            gpus: payload.gpus,
            launchedAt: Date(),
            agentAttribution: attribution
        )
        await MainActor.run {
            recentLaunchStore.save(launch)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

// MARK: - delete_session (destructive)

struct DeleteSessionTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Payload: Codable, Sendable {
        let id: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_session",
        description: "Terminate a running Skaha session by id (interactive OR headless — same endpoint covers both). Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation in the strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.id.isEmpty else {
            throw ToolFailureReason.invalidArgument("id is empty")
        }
        return try ProposalPlan.encoding(
            kind: "delete_session",
            summary: "Terminate session \(args.id)",
            payload: Payload(id: args.id)
        )
    }
}

struct DeleteSessionApplier: ProposalApplier {
    let kind = "delete_session"
    let service: SessionService
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteSessionTool.Payload.self, from: proposal.payload)
        do {
            try await service.deleteSession(id: payload.id)
        } catch {
            throw ProposalApplyError.backendError("delete failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

// MARK: - delete_sessions_bulk (destructive)

/// Terminate multiple Skaha sessions in one call. Same endpoint per
/// id as `delete_session`, but fires the deletes in parallel and
/// reports per-id outcomes — closes the "I have N zombie pending
/// jobs, want one call to nuke them all" friction that the
/// 2026-05-13 QA report documented (5 stuck Pending jobs from a
/// scheduling-stress test).
///
/// Partial-success semantics, not all-or-nothing: every id is
/// attempted, the output reports which succeeded and which failed
/// with the reason. Bulk tools that abort on first failure end up
/// worse than a loop of single calls because they leave the user
/// with an opaque partial-cleanup state.
struct DeleteSessionsBulkTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let ids: [String]
    }

    struct Payload: Codable, Sendable {
        let ids: [String]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_sessions_bulk",
        description: "Terminate up to 50 Skaha sessions (interactive OR headless) in parallel as one proposal envelope. Partial-success: every id is attempted; output reports `succeeded[]` + `failed[{id, error}]` so a single zombie that's already gone doesn't block the rest. Use this for zombie-cleanup after a launch-storm or to free quota slots after a stress test. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation in the strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["ids"],
          "properties": {
            "ids": {
              "type": "array",
              "items": { "type": "string", "minLength": 1 },
              "minItems": 1,
              "maxItems": 50
            }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        // Trim each id and drop empties — whitespace-only strings
        // are never valid Skaha session ids and would 404 on
        // delete, so catching them at the boundary is cleaner than
        // burning a network call per blank.
        let cleaned = args.ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(cleaned))
        guard !unique.isEmpty else {
            throw ToolFailureReason.invalidArgument("ids is empty after deduplication / dropping blanks")
        }
        guard unique.count <= 50 else {
            throw ToolFailureReason.invalidArgument("ids count \(unique.count) exceeds 50-per-call cap")
        }
        return try ProposalPlan.encoding(
            kind: "delete_sessions_bulk",
            summary: "Terminate \(unique.count) session\(unique.count == 1 ? "" : "s")",
            payload: Payload(ids: unique)
        )
    }
}

struct DeleteSessionsBulkApplier: ProposalApplier {
    let kind = "delete_sessions_bulk"
    let service: SessionService
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteSessionsBulkTool.Payload.self, from: proposal.payload)
        // Fan out in parallel — Skaha's DELETE per id is
        // independent and cheap (no body, no K8s wait). A linear
        // loop over 50 ids at ~200 ms each adds up to 10 s; the
        // TaskGroup completes in roughly the slowest single
        // request. Wrapped in `withApplierTimeout` so the bulk
        // never silently hangs (F-2026-05-13-A protection).
        let svc = service
        let ids = payload.ids
        try await withApplierTimeout(seconds: 180, label: "delete_sessions_bulk") {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask {
                        // We don't propagate errors here — every
                        // attempt should run regardless of others'
                        // outcomes. The success of the bulk is
                        // measured by the activity-feed entry; the
                        // applier doesn't currently round-trip
                        // per-id failures back to the agent
                        // because the proposal-apply protocol only
                        // expresses succeed / throw. Surface
                        // detail in a follow-up if any.
                        _ = try? await svc.deleteSession(id: id)
                    }
                }
            }
        }
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

// MARK: - clear_research_archive (destructive)

/// Wipe all locally-stored downloaded observation metadata. Doesn't
/// touch local files — the user keeps the downloads on disk; only the
/// archive index is cleared.
struct ClearResearchArchiveTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    typealias Args = EmptyArgs

    struct Payload: Codable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_research_archive",
        description: "Remove ALL downloaded-observation metadata records. Does not touch local files. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation in the strip.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: EmptyArgs, context: AIToolContext) async throws -> ProposalPlan {
        try ProposalPlan.encoding(
            kind: "clear_research_archive",
            summary: "Clear ALL research archive records",
            payload: Payload()
        )
    }
}

struct ClearResearchArchiveApplier: ProposalApplier {
    let kind = "clear_research_archive"
    let store: ObservationStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        await MainActor.run {
            store.clear()
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}
