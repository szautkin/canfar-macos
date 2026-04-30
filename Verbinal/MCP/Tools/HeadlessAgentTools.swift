// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - Shared envelope

/// Wire-encoded environment variable pair. Used by the launch tool's
/// args + payload. JSON `[String: String]` would lose insertion order
/// once decoded into a Swift dictionary, so the agent passes an array
/// of `{key, value}` objects — explicit, ordered, simple.
struct AgentEnvVar: Codable, Sendable, Equatable {
    let key: String
    let value: String
}

// MARK: - launch_headless_job (write)

/// Launch one or more replicas of a headless Skaha batch job. Mirrors
/// the in-app HeadlessLaunchTabView surface — same service path, same
/// auto-applied-via-autonomy-toggle treatment as `launch_session`.
struct LaunchHeadlessJobTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let name: String
        let image: String
        var cmd: String?
        var args: String?
        var env: [AgentEnvVar]?
        var cores: Int?
        var ram: Int?
        var gpus: Int?
        var replicas: Int?
    }

    struct Payload: Codable, Sendable {
        let name: String
        let image: String
        let cmd: String?
        let args: String?
        let env: [AgentEnvVar]
        let cores: Int?
        let ram: Int?
        let gpus: Int?
        let replicas: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "launch_headless_job",
        description: "Launch one or more replicas of a headless Skaha batch job. The `image` MUST be a value returned by `list_session_images` filtered to `type: \"headless\"` — hand-typed strings will fail with HTTP 400 'unknown or private image'. `cmd` is the command the container runs (required for any useful work; technically optional). `args` is a SINGLE space-separated string (Skaha treats it as one parameter and splits server-side). `env` is an ordered array of {key, value} pairs — each becomes a repeated `env=KEY=VAL` form field on the wire. `replicas` ≥ 2 spawns N parallel containers with names suffixed `-1, -2, …`; REPLICA_ID and REPLICA_COUNT are auto-injected into each replica's env. Returns the launched job id(s) — partial-replica failure is reported as a backendError with the count of replicas that DID land.",
        schema: #"""
        {
          "type": "object",
          "required": ["name", "image"],
          "properties": {
            "name":     { "type": "string", "minLength": 1 },
            "image":    { "type": "string", "minLength": 1 },
            "cmd":      { "type": "string" },
            "args":     { "type": "string" },
            "env":      {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["key", "value"],
                "properties": {
                  "key":   { "type": "string", "minLength": 1 },
                  "value": { "type": "string" }
                },
                "additionalProperties": false
              }
            },
            "cores":    { "type": "integer", "minimum": 1 },
            "ram":      { "type": "integer", "minimum": 1 },
            "gpus":     { "type": "integer", "minimum": 0 },
            "replicas": { "type": "integer", "minimum": 1, "maximum": 50 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let replicas = max(1, args.replicas ?? 1)
        let env = args.env ?? []
        let payload = Payload(
            name: args.name, image: args.image,
            cmd: args.cmd, args: args.args, env: env,
            cores: args.cores, ram: args.ram, gpus: args.gpus,
            replicas: replicas
        )
        let summary: String
        if replicas == 1 {
            summary = "Launch headless job '\(args.name)' — image: \(args.image)"
        } else {
            summary = "Launch \(replicas) headless replicas of '\(args.name)' — image: \(args.image)"
        }
        return try ProposalPlan.encoding(
            kind: "launch_headless_job",
            summary: summary,
            payload: payload
        )
    }
}

struct LaunchHeadlessJobApplier: ProposalApplier {
    let kind = "launch_headless_job"
    let service: HeadlessService
    let recentLaunchStore: RecentLaunchStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(LaunchHeadlessJobTool.Payload.self, from: proposal.payload)
        let params = HeadlessLaunchParams(
            name: payload.name,
            image: payload.image,
            cmd: payload.cmd,
            args: payload.args,
            env: payload.env.map { ($0.key, $0.value) },
            cores: payload.cores,
            ram: payload.ram,
            gpus: payload.gpus,
            replicas: payload.replicas
        )

        let launchedIDs: [String]
        do {
            launchedIDs = try await service.launchHeadlessJob(params)
        } catch let HeadlessLaunchError.partialReplicaFailure(launched, idx, message) {
            // Persist what DID land so the user / agent can reason about
            // the partial state.
            await persist(ids: launched, payload: payload, proposal: proposal)
            throw ProposalApplyError.backendError(
                "Replica \(idx + 1) failed: \(message). \(launched.count) replicas already running (ids: \(launched.joined(separator: ", ")))."
            )
        } catch HeadlessLaunchError.emptyResponse {
            throw ProposalApplyError.backendError("Skaha returned an empty response.")
        } catch {
            throw ProposalApplyError.backendError("headless launch failed: \(error.localizedDescription)")
        }

        await persist(ids: launchedIDs, payload: payload, proposal: proposal)
    }

    @MainActor
    private func persist(
        ids: [String],
        payload: LaunchHeadlessJobTool.Payload,
        proposal: PendingProposal
    ) async {
        let attribution = AgentAttribution.from(proposal: proposal)
        for (idx, _) in ids.enumerated() {
            let displayName = ids.count == 1 ? payload.name : "\(payload.name)-\(idx + 1)"
            let launch = RecentLaunch(
                name: displayName,
                type: "headless",
                image: payload.image,
                imageLabel: payload.image,
                project: "",
                resourceType: payload.cores != nil ? "fixed" : "flexible",
                cores: payload.cores ?? 0,
                ram: payload.ram ?? 0,
                gpus: payload.gpus ?? 0,
                launchedAt: Date(),
                agentAttribution: attribution
            )
            recentLaunchStore.save(launch)
        }
        activity.append(.applied(proposal: proposal, kind: kind))
    }
}

// MARK: - list_headless_jobs (read)

struct ListHeadlessJobsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let jobs: [Entry]
        struct Entry: Encodable, Sendable {
            let id: String
            let name: String
            let status: String
            let image: String
            let imageLabel: String
            let startedTime: String
            let expiresTime: String
            let memoryAllocated: String
            let cpuAllocated: String
            let gpuAllocated: String
            /// `pending`, `running`, `completed`, `failed`, or `unknown`.
            /// Derived from `status` to spare the agent a parse step.
            let phase: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_headless_jobs",
        description: "List the user's headless Skaha batch jobs (any status: pending/running/completed/failed). Use to check status across replicas after `launch_headless_job`. For a single job by id, use `get_headless_job`.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable () async throws -> [HeadlessJob]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let jobs: [HeadlessJob]
        do {
            jobs = try await fetch()
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
        return Output(jobs: jobs.map(Self.entry(from:)))
    }

    static func entry(from job: HeadlessJob) -> Output.Entry {
        Output.Entry(
            id: job.id,
            name: job.name,
            status: job.status,
            image: job.image,
            imageLabel: job.imageLabel,
            startedTime: job.startedTime,
            expiresTime: job.expiresTime,
            memoryAllocated: job.memoryAllocated,
            cpuAllocated: job.cpuAllocated,
            gpuAllocated: job.gpuAllocated,
            phase: phase(of: job)
        )
    }

    private static func phase(of job: HeadlessJob) -> String {
        if job.isPending   { return "pending" }
        if job.isRunning   { return "running" }
        if job.isCompleted { return "completed" }
        if job.isFailed    { return "failed" }
        return "unknown"
    }
}

// MARK: - get_headless_job (read)

struct GetHeadlessJobTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    typealias Output = ListHeadlessJobsTool.Output.Entry

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job",
        description: "Look up one headless job by id. Returns the same shape as `list_headless_jobs[i]`. Throws unknownTarget if the id isn't in the current job list (terminated jobs drop out of the listing after Skaha's retention window).",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable () async throws -> [HeadlessJob]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let jobs: [HeadlessJob]
        do {
            jobs = try await fetch()
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
        guard let job = jobs.first(where: { $0.id == args.id }) else {
            throw ToolFailureReason.unknownTarget(args.id)
        }
        return ListHeadlessJobsTool.entry(from: job)
    }
}

// MARK: - get_headless_job_logs (read)

struct GetHeadlessJobLogsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Output: Encodable, Sendable {
        let id: String
        let logs: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job_logs",
        description: "Fetch container stdout/stderr for a headless job by id. Returns plain-text content (newline-delimited; whatever Kubernetes' pod-log endpoint emits). For long-running jobs the response is the snapshot at request time — not a live tail.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable (_ id: String) async throws -> String

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        do {
            let logs = try await fetch(args.id)
            return Output(id: args.id, logs: logs)
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
    }
}

// MARK: - get_headless_job_events (read)

struct GetHeadlessJobEventsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Output: Encodable, Sendable {
        let id: String
        let events: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job_events",
        description: "Fetch Kubernetes-level events for a headless job by id (scheduling decisions, pull errors, OOM kills, etc). Plain-text content. Useful when a job is stuck in pending or failed for unobvious reasons.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable (_ id: String) async throws -> String

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        do {
            let events = try await fetch(args.id)
            return Output(id: args.id, events: events)
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
    }
}
