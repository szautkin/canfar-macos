// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `run_code` — run agent code IMMEDIATELY on a warm **contributed**
/// interactive Skaha session, skipping the headless **batch** queue
/// (which can sit `Pending` for hours under cluster load).
///
/// Mechanism (the FILE-DROP contract — see
/// `dev_info/verbinal-compute-image-spec.md`): Skaha has no exec API and
/// ignores `cmd`/`args` for contributed sessions, so the agent's code
/// cannot ride in at launch. Instead the configured compute image bakes a
/// watcher loop as its entrypoint; the app and the session communicate
/// through the shared `/arc` filesystem. This tool writes the request to
/// `~/.verbinal/exec/inbox/<id>.json`; the watcher runs it and writes
/// `~/.verbinal/exec/out/<id>.json`; the agent reads that back with
/// `run_code_output`.
///
/// Why a TWO-tool hybrid (`run_code` write + `run_code_output` read): an
/// auto-apply-gated write's applier returns `Void` — it cannot hand
/// stdout back to the agent. So the write enqueues/drops the request
/// (gated by the autonomy toggle, like every other write) and returns an
/// `execution_id`; the read tool owns fetching the rich result. This is
/// the same shape as `launch_headless_job` + `get_headless_job_logs`, and
/// it also keeps the single-threaded MCP transport from being blocked by
/// a long synchronous exec.

// MARK: - run_code (auto-apply-gated write)

struct RunCodeTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    /// Injected so the disabled-when-unset check is testable without
    /// touching `UserDefaults.standard`. Production reads the setting the
    /// AI-Remote-Compute Settings section writes.
    let resolveImage: @Sendable () -> String

    /// The configured default instance size for the LAZY self-launch
    /// (when no compute instance is warm). Resources are not a per-call
    /// `run_code` knob — the agent sizes the instance up-front via
    /// `start_compute`; `run_code` only consumes whatever default size
    /// the user picked in Settings ▸ Compute. Injected for testing.
    let resolveResources: @Sendable () -> (cores: Int, ram: Int)

    init(resolveImage: @escaping @Sendable () -> String = { AIComputeImage.resolvedImageID() },
         resolveResources: @escaping @Sendable () -> (cores: Int, ram: Int) = { AIComputeImage.resolvedResources() }) {
        self.resolveImage = resolveImage
        self.resolveResources = resolveResources
    }

    struct Args: Decodable, Sendable {
        let code: String
        var language: String?
        var timeout_seconds: Int?
    }

    /// Carried to the applier (and the applier alone writes to /arc).
    /// `cores`/`ram` size the LAZY self-launch only — they're resolved
    /// from the Settings default here so the applier can launch a warm
    /// instance at the configured size when none exists yet.
    struct Payload: Codable, Sendable {
        let id: String
        let language: String
        let code: String
        let timeout_seconds: Int
        let image: String
        let cores: Int
        let ram: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "run_code",
        description: "Run a short Python or bash snippet IMMEDIATELY on a warm interactive CANFAR compute session, skipping the headless batch queue (which can sit Pending for hours). Your code is dropped onto the session via the shared /arc filesystem; the running compute image executes it and writes the result back. Returns an `execution_id` — then call `run_code_output` with that id to fetch stdout/stderr/exit_code (poll a few times if still running; the FIRST call may take a minute or two while the session provisions, then subsequent calls are warm). USE FOR: quick checks, REPL-style iteration, inspecting data you just downloaded, sanity-running a snippet before scaling it up. DO NOT USE FOR: long-running, batch, parallel, or multi-hour work, or anything that must survive your disconnection — use `launch_headless_job` for that (queued, durable, poll with get_headless_job_logs). RULE OF THUMB: if you'd wait and watch for the result → run_code; if you'd submit and come back later → launch_headless_job. Requires an AI compute image configured in Settings ▸ Compute; if it is unset this errors and you should fall back to launch_headless_job. Resources come from your Settings ▸ Compute default (or whatever size `start_compute` already gave the running instance); to run heavier code, size the instance up with `start_compute` first, or use `launch_headless_job`.",
        schema: #"""
        {
          "type": "object",
          "required": ["code"],
          "properties": {
            "code": { "type": "string", "minLength": 1 },
            "language": { "type": "string", "enum": ["python", "bash"] },
            "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 900 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let image = resolveImage().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else {
            throw ToolFailureReason.invalidArgument(
                "run_code is disabled: set an AI compute image in Settings ▸ Compute first, or use launch_headless_job instead.")
        }
        guard !args.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolFailureReason.invalidArgument("code is empty")
        }
        let language = (args.language ?? "python").lowercased()
        guard RunCodeContract.supportedLanguages.contains(language) else {
            throw ToolFailureReason.invalidArgument(
                "language must be one of: \(RunCodeContract.supportedLanguages.joined(separator: ", "))")
        }
        let timeout = min(max(args.timeout_seconds ?? RunCodeContract.defaultTimeoutSeconds, 1),
                          RunCodeContract.maxTimeoutSeconds)
        // Lazy-launch size: the Settings default, clamped. Not exposed as
        // a per-call argument — resources are an instance property the
        // agent sets via `start_compute`.
        let resolved = resolveResources()
        let cores = RunCodeContract.clampCores(resolved.cores)
        let ram = RunCodeContract.clampRam(resolved.ram)
        let id = UUID().uuidString
        let lines = args.code.split(separator: "\n", omittingEmptySubsequences: false).count
        let summary = "Run a \(lines)-line \(language) snippet on the AI compute session (≤\(timeout)s) — " +
                      "execution_id \(id). Fetch the result with run_code_output(execution_id: \"\(id)\")."
        return try ProposalPlan.encoding(
            kind: "run_code",
            summary: summary,
            payload: Payload(id: id, language: language, code: args.code, timeout_seconds: timeout,
                             image: image, cores: cores, ram: ram)
        )
    }
}

// MARK: - run_code applier (ensures the warm session + drops the request)

struct RunCodeApplier: ProposalApplier {
    let kind = "run_code"
    /// Sends the request as the assistant's, launching the session from the
    /// configuration the proposal was planned with when there is none.
    let submit: @Sendable (RunCodeContract.Request, RemoteComputeService.Configuration) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RunCodeTool.Payload.self, from: proposal.payload)
        let request = RunCodeContract.Request(id: payload.id, language: payload.language,
                                              code: payload.code, timeout_seconds: payload.timeout_seconds)
        let launch = RemoteComputeService.Configuration(image: payload.image, cores: payload.cores, ram: payload.ram)
        let submit = submit
        // A 3-minute deadline so a stalled launch or upload always ends.
        do {
            try await withApplierTimeout(seconds: 180, label: "run_code") { try await submit(request, launch) }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("run_code: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}

// MARK: - run_code_output (read; polls the result file)

struct RunCodeOutputTool: AITool {
    static var verbClass: VerbClass { .read }
    static var agentSafe: Bool { true }

    /// Reads the run's result file (and records it). Injected for testing.
    let fetchOut: @Sendable (_ executionID: String) async throws -> RunCodeContract.Fetched

    var toolTimeoutSeconds: TimeInterval { 30 }

    struct Args: Decodable, Sendable { let execution_id: String }

    let definition = AIToolDefinition.withStaticSchema(
        name: "run_code_output",
        description: "Check the status of / fetch the result of a `run_code` execution by its `execution_id`. Returns `{ ready: true, status, exit_code, stdout, stderr, ... }` once the compute session has finished, or `{ ready: false }` while it is still starting/executing — in that case poll again shortly (the first execution after a cold start can take a minute or two while the session provisions). `status` is the authoritative outcome: \"ok\" (exit 0), \"error\" (non-zero exit or rejected), or \"timeout\". `stdout`/`stderr` are UTF-8 text unless the matching `stdout_encoding`/`stderr_encoding` is \"base64\" (binary output) — decode the base64 yourself in that case. This is a read; it never executes anything.",
        schema: #"""
        {
          "type": "object",
          "required": ["execution_id"],
          "properties": { "execution_id": { "type": "string", "minLength": 1 } },
          "additionalProperties": false
        }
        """#
    )

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do { args = try JSONDecoder().decode(Args.self, from: arguments) }
        catch { return .failed(.invalidArgument("\(error)")) }
        let id = args.execution_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .failed(.invalidArgument("execution_id is required")) }
        do {
            return try await withToolTimeout(seconds: toolTimeoutSeconds, label: "run_code_output") {
                try await self.run(id: id)
            }
        } catch let reason as ToolFailureReason {
            return .failed(reason)
        } catch {
            return .failed(.backendError("run_code_output: \(error.localizedDescription)"))
        }
    }

    private func run(id: String) async throws -> ToolResult {
        switch try await fetchOut(id) {
        case .absent:
            return Self.encode(Output(ready: false, execution_id: id,
                note: "No result yet — the compute session may still be provisioning or executing. Retry run_code_output shortly; if several polls still return nothing, the session may have stopped — call start_compute (or run_code) to (re)launch it."))
        case .incomplete:
            // A partial/propagating write (read-after-write lag on /arc) — keep polling.
            return Self.encode(Output(ready: false, execution_id: id,
                note: "Result file is present but not yet complete; retry shortly."))
        case .done(let result):
            return Self.encode(Output(
                ready: true, execution_id: id,
                status: result.status, exit_code: result.exit_code,
                stdout: result.stdout, stdout_encoding: result.stdout_encoding,
                stderr: result.stderr, stderr_encoding: result.stderr_encoding,
                duration_ms: result.duration_ms, truncated: result.truncated,
                started_at: result.started_at, finished_at: result.finished_at))
        }
    }

    struct Output: Encodable {
        let ready: Bool
        let execution_id: String
        var status: String? = nil
        var exit_code: Int? = nil
        var stdout: String? = nil
        var stdout_encoding: String? = nil
        var stderr: String? = nil
        var stderr_encoding: String? = nil
        var duration_ms: Int? = nil
        var truncated: Bool? = nil
        var started_at: String? = nil
        var finished_at: String? = nil
        var note: String? = nil
    }

    private static func encode(_ out: Output) -> ToolResult {
        if let data = try? JSONEncoder().encode(out) { return .data(data) }
        return .failed(.backendError("run_code_output: failed to encode result"))
    }
}
