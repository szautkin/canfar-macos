// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Explicit lifecycle for the AI-Remote-Compute instance — the warm
/// `contributed` Skaha session `run_code` drives via the /arc file-drop
/// (`RunCodeContract`). `run_code` STAYS LAZY: it self-launches at the
/// Settings-default size when nothing is warm, so these two tools are an
/// *optional* pre-warm/sizing + teardown layer on top of it.
///
/// `start_compute` lets the agent pick the instance size up-front (else
/// the configured default), which matters because resources are an
/// INSTANCE property fixed for the session's lifetime — there is no
/// resize. To grow/shrink: `stop_compute` then `start_compute` again.
///
/// `stop_compute` tears the instance down by NAME (no session id needed),
/// idempotently. Both share `RunCodeContract` so the session-name /
/// reuse-decision literals stay single-sourced with `run_code`.

// MARK: - start_compute (explicit launch + agent-selectable resources)

struct StartComputeTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    /// Same injection story as `RunCodeTool`: the image + the default
    /// instance size resolve from Settings ▸ Compute without an
    /// `AppState`/MainActor hop, and are stubbable in tests.
    let resolveImage: @Sendable () -> String
    let resolveResources: @Sendable () -> (cores: Int, ram: Int)

    init(resolveImage: @escaping @Sendable () -> String = { AIComputeImage.resolvedImageID() },
         resolveResources: @escaping @Sendable () -> (cores: Int, ram: Int) = { AIComputeImage.resolvedResources() }) {
        self.resolveImage = resolveImage
        self.resolveResources = resolveResources
    }

    struct Args: Decodable, Sendable {
        var cores: Int?
        var ram: Int?
    }

    /// Carried to the applier. Resolved + clamped at plan time so the
    /// applier just launches with these values.
    struct Payload: Codable, Sendable {
        let cores: Int
        let ram: Int
        let image: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "start_compute",
        description: "Launch OR reuse the warm `verbinal-compute` contributed session that `run_code` runs on — an OPTIONAL pre-warm/sizing step (run_code self-launches a default-sized instance on its own, so you only need this when you want to control the size or warm the session up before iterating). `cores`/`ram` set the instance size: pass them to size it, otherwise the configured Settings ▸ Compute default is used. IMPORTANT: resources are FIXED once the instance is running — you CANNOT resize a live instance. If one is already running, this no-ops and keeps the current size; to change size you must `stop_compute` first, then `start_compute` again with the new size. Out-of-range values are clamped to 1–64 cores / 1–256 GB; the sizes your CANFAR deployment actually offers may be narrower, and an unavailable size surfaces as a launch error you can then adjust. Requires an AI compute image configured in Settings ▸ Compute. Gated like other writes: runs immediately when auto-apply is on, otherwise waits for confirmation in the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "cores": { "type": "integer" },
            "ram":   { "type": "integer" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let image = resolveImage().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else {
            throw ToolFailureReason.invalidArgument(
                "start_compute is disabled: set an AI compute image in Settings ▸ Compute first, or use launch_headless_job instead.")
        }
        let resolved = resolveResources()
        let cores = RunCodeContract.clampCores(args.cores ?? resolved.cores)
        let ram = RunCodeContract.clampRam(args.ram ?? resolved.ram)
        let summary = "Start/ensure the \(RunCodeContract.sessionName) instance " +
                      "(\(cores) cores / \(ram) GB). Run code on it with run_code."
        return try ProposalPlan.encoding(
            kind: "start_compute",
            summary: summary,
            payload: Payload(cores: cores, ram: ram, image: image)
        )
    }
}

// MARK: - start_compute applier (reuse-or-launch + ensure the /arc tree)

struct StartComputeApplier: ProposalApplier {
    let kind = "start_compute"
    let service: SessionService
    let vospace: VOSpaceBrowserService
    let username: @Sendable () async -> String
    /// Raw (username, secret) for the compute image's registry, so a
    /// PRIVATE image can be pulled at cold-launch. nil ⇒ public image.
    let registryAuth: @Sendable () async -> (username: String, secret: String)?
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(StartComputeTool.Payload.self, from: proposal.payload)
        let user = await username()
        guard !user.isEmpty else {
            throw ProposalApplyError.backendError("start_compute: not authenticated (no CADC username).")
        }
        let svc = service
        let vos = vospace
        let auth = registryAuth
        let image = payload.image

        // Whether we launched a new instance (vs. reused a warm one),
        // captured so the activity breadcrumb is honest about which.
        var reusedExisting = false

        do {
            try await withApplierTimeout(seconds: 180, label: "start_compute") {
                let sessions = try await svc.getSessions()
                let infos = sessions.map {
                    RunCodeContract.SessionInfo(id: $0.id, type: $0.sessionType,
                                                name: $0.sessionName, status: $0.status)
                }
                if RunCodeContract.reusableSessionID(in: infos, name: RunCodeContract.sessionName) != nil {
                    // A warm (running/pending) instance already exists.
                    // We CANNOT resize it — leave it at its current size
                    // and treat this as a successful no-op.
                    reusedExisting = true
                    return
                }
                // Launch a new instance at the requested size. Pass the
                // compute registry creds so Skaha can pull a private image.
                let creds = await auth()
                let params = SessionLaunchParams(
                    type: RunCodeContract.sessionType,
                    name: RunCodeContract.sessionName,
                    image: image,
                    cores: payload.cores, ram: payload.ram, gpus: 0,
                    cmd: nil,
                    registryUsername: creds?.username,
                    registrySecret: creds?.secret
                )
                _ = try await svc.launchSession(params)
                // Defensively ensure the /arc inbox tree exists so the
                // first `run_code` PUT doesn't 404 on a missing parent.
                await RunCodeApplier.ensureTree(vos, user: user)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("start_compute: \(error.localizedDescription)")
        }

        // Note in the feed whether we reused a running instance (and so
        // honoured its current size, not the requested one) or launched
        // fresh — the user/agent can see why a resize "didn't take".
        let summary = reusedExisting
            ? "Reused the existing \(RunCodeContract.sessionName) instance at its current size — a running instance can't be resized (stop_compute then start_compute to change it)."
            : proposal.summary
        await MainActor.run {
            activity.append(.applied(
                proposal: PendingProposal(
                    id: proposal.id, toolName: proposal.toolName, kind: proposal.kind,
                    summary: summary, payload: proposal.payload,
                    createdAt: proposal.createdAt, origin: proposal.origin,
                    requestID: proposal.requestID),
                kind: kind))
        }
    }
}

// MARK: - stop_compute (teardown, destructive)

struct StopComputeTool: JSONWriteTool {
    // .destructive (it tears down a session); JSONWriteTool already
    // defaults `agentSafe` to true, matching the destructive siblings.
    static let verbClass: VerbClass = .destructive

    typealias Args = EmptyArgs

    struct Payload: Codable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "stop_compute",
        description: "Tear down the `verbinal-compute` instance by name (no session id needed) — frees its cores/RAM. Idempotent: a clean no-op if none is running. Use this to release resources when you're done, or to change the instance size (stop, then `start_compute` with the new size). IMPORTANT — stop is NOT cancel: a `run_code` request you've already dropped that hasn't produced a result yet stays queued in the /arc inbox, so it WILL re-execute (possibly re-running side-effecting code) the next time the instance starts. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation in the strip.",
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
            kind: "stop_compute",
            summary: "Stop the \(RunCodeContract.sessionName) instance (frees its cores/RAM).",
            payload: Payload()
        )
    }
}

struct StopComputeApplier: ProposalApplier {
    let kind = "stop_compute"
    let service: SessionService
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let svc = service
        var foundRunning = false
        do {
            try await withApplierTimeout(seconds: 180, label: "stop_compute") {
                let sessions = try await svc.getSessions()
                let infos = sessions.map {
                    RunCodeContract.SessionInfo(id: $0.id, type: $0.sessionType,
                                                name: $0.sessionName, status: $0.status)
                }
                guard let id = RunCodeContract.reusableSessionID(
                    in: infos, name: RunCodeContract.sessionName) else {
                    // Clean no-op — nothing to stop.
                    return
                }
                foundRunning = true
                try await svc.deleteSession(id: id)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("stop_compute: \(error.localizedDescription)")
        }

        let summary = foundRunning
            ? proposal.summary
            : "No compute instance running — stop_compute was a no-op."
        await MainActor.run {
            activity.append(.applied(
                proposal: PendingProposal(
                    id: proposal.id, toolName: proposal.toolName, kind: proposal.kind,
                    summary: summary, payload: proposal.payload,
                    createdAt: proposal.createdAt, origin: proposal.origin,
                    requestID: proposal.requestID),
                kind: kind))
        }
    }
}
