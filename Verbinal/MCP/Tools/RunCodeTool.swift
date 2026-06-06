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

// MARK: - Contract (shared, pinned literals + types)

/// The file-drop contract literals. These MUST stay byte-for-byte in sync
/// with the watcher image (`dev_info/verbinal-compute-image-spec.md`); a
/// mismatch fails silently (the agent polls an output file the watcher
/// wrote elsewhere).
enum RunCodeContract {
    static let sessionName = "verbinal-compute"
    static let sessionType = "contributed"
    static let inboxDir = ".verbinal/exec/inbox"
    static let outDir   = ".verbinal/exec/out"
    /// Result file hard cap — matches `read_vospace_file`'s 1 MB ceiling.
    static let maxResultBytes = 1024 * 1024
    static let supportedLanguages = ["python", "bash"]
    static let defaultTimeoutSeconds = 60
    static let maxTimeoutSeconds = 900

    /// Resource bounds for the compute instance. The default size is the
    /// Settings-resolved value (`AIComputeImage.resolvedResources()`);
    /// these constants are the floor (1) the lazy launch falls back to
    /// and the ceiling agent-requested sizes are clamped to. Resources
    /// are an INSTANCE property — set once at `start_compute` (or the
    /// `run_code` self-launch) and fixed for that instance's lifetime.
    static let defaultCores = 1
    static let defaultRam = 1
    static let maxCores = 64
    static let maxRam = 256

    static func clampCores(_ value: Int) -> Int { min(max(value, 1), maxCores) }
    static func clampRam(_ value: Int) -> Int { min(max(value, 1), maxRam) }

    /// Sanitize a request id for filesystem use. The 9-character set
    /// `/ : \ ? * < > | "` MUST match the watcher image and Verbinal's
    /// `ImageManifest.sanitize` byte-for-byte, or id-derived filenames
    /// won't agree across the two sides.
    static func sanitize(_ id: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "?", "*", "<", ">", "|", "\""]
        return String(id.map { bad.contains($0) ? "_" : $0 })
    }
    static func inboxPath(id: String) -> String { "\(inboxDir)/\(sanitize(id)).json" }
    static func outPath(id: String) -> String { "\(outDir)/\(sanitize(id)).json" }

    /// Client → watcher. Single JSON object PUT to the inbox.
    struct Request: Codable, Sendable {
        let id: String
        let language: String
        let code: String
        let timeout_seconds: Int
    }

    /// Watcher → client. Decoded leniently (every field optional) so a
    /// partially-written or older-schema result degrades to "not ready"
    /// rather than throwing.
    struct ResultFile: Codable, Sendable {
        let id: String?
        let status: String?
        let exit_code: Int?
        let stdout: String?
        let stdout_encoding: String?
        let stderr: String?
        let stderr_encoding: String?
        let duration_ms: Int?
        let truncated: Bool?
        let started_at: String?
        let finished_at: String?
    }

    /// Minimal view of a session for the reuse decision — keeps the pure
    /// choice logic testable without the Session model.
    struct SessionInfo: Sendable, Equatable {
        let id: String
        let type: String
        let name: String
        let status: String   // raw Skaha status: running / pending / terminating / …
    }

    /// The id of a warm session to reuse, or nil to launch a new one: a
    /// `contributed` session WE launched (matched by its pinned name) that is
    /// running OR still provisioning (`pending`) — never terminating/failed.
    /// Matching by name (not the image string) is robust to `launchSession`'s
    /// registry-prefix normalization, and counting `pending` stops rapid
    /// cold-start calls from spawning duplicate sessions.
    static func reusableSessionID(in sessions: [SessionInfo], name: String) -> String? {
        sessions.first { s in
            let status = s.status.lowercased()
            return s.type.lowercased() == sessionType
                && s.name == name
                && (status == "running" || status == "pending")
        }?.id
    }
}

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
        description: "Run a short Python or bash snippet IMMEDIATELY on a warm interactive CANFAR compute session, skipping the headless batch queue (which can sit Pending for hours). Your code is dropped onto the session via the shared /arc filesystem; the running compute image executes it and writes the result back. Returns an `execution_id` — then call `run_code_output` with that id to fetch stdout/stderr/exit_code (poll a few times if still running; the FIRST call may take a minute or two while the session provisions, then subsequent calls are warm). USE FOR: quick checks, REPL-style iteration, inspecting data you just downloaded, sanity-running a snippet before scaling it up. DO NOT USE FOR: long-running, batch, parallel, or multi-hour work, or anything that must survive your disconnection — use `launch_headless_job` for that (queued, durable, poll with get_headless_job_logs). RULE OF THUMB: if you'd wait and watch for the result → run_code; if you'd submit and come back later → launch_headless_job. Requires an AI compute image configured in Settings ▸ Compute; if it is unset this errors and you should fall back to launch_headless_job. Running code is gated like other writes: it runs immediately when auto-apply is on, otherwise it waits for the user to confirm in the proposal strip. Resources come from your Settings ▸ Compute default (or whatever size `start_compute` already gave the running instance); to run heavier code, size the instance up with `start_compute` first, or use `launch_headless_job`.",
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
    let service: SessionService
    let vospace: VOSpaceBrowserService
    let username: @Sendable () async -> String
    /// Raw (username, secret) for the registry the compute image lives in,
    /// so a PRIVATE image can be pulled at cold-launch. nil ⇒ public image
    /// / no creds configured (Settings ▸ Compute).
    let registryAuth: @Sendable () async -> (username: String, secret: String)?
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RunCodeTool.Payload.self, from: proposal.payload)
        let user = await username()
        guard !user.isEmpty else {
            throw ProposalApplyError.backendError("run_code: not authenticated (no CADC username).")
        }
        let svc = service
        let vos = vospace
        let auth = registryAuth
        let image = payload.image

        // 3-minute deadline so a stalled launch/upload always emits a
        // terminal event rather than hanging the strip.
        do {
            try await withApplierTimeout(seconds: 180, label: "run_code") {
                // 1. Reuse a warm contributed compute session, or launch one.
                //    We don't wait for Running — once the watcher boots it
                //    re-scans the inbox and runs anything already dropped, and
                //    the agent polls run_code_output until the result lands.
                //    NOTE: the spec's status.json readiness gate (assert
                //    ready:true + matching resolved_user BEFORE the first PUT) is
                //    deferred together with the renew timer until the
                //    contributed-session-stays-Running question (ticket #28) is
                //    validated; until then a genuine cold start relies on
                //    ensureTree below + the watcher boot re-scan.
                let sessions = try await svc.getSessions()
                let infos = sessions.map {
                    RunCodeContract.SessionInfo(id: $0.id, type: $0.sessionType,
                                                name: $0.sessionName, status: $0.status)
                }
                if RunCodeContract.reusableSessionID(in: infos, name: RunCodeContract.sessionName) == nil {
                    // Pass the compute registry creds (Settings ▸ Compute) so
                    // Skaha can mint x-skaha-registry-auth and pull a PRIVATE
                    // image; nil for a public image.
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
                }

                // 2. Defensively ensure the inbox tree exists. The watcher is
                //    the source of truth, but a just-launched session may not
                //    have created it yet — a missing parent 404s the PUT.
                await Self.ensureTree(vos, user: user)

                // 3. Drop the request into the inbox (single PUT).
                let request = RunCodeContract.Request(
                    id: payload.id, language: payload.language,
                    code: payload.code, timeout_seconds: payload.timeout_seconds)
                let data = try JSONEncoder().encode(request)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("runcode-\(RunCodeContract.sanitize(payload.id)).json")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await vos.uploadFile(
                    username: user,
                    remotePath: RunCodeContract.inboxPath(id: payload.id),
                    fileURL: tmp)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("run_code: \(error.localizedDescription)")
        }

        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }

    /// Create the coordination tree, one container per call, ignoring
    /// "already exists" (createFolder throws on conflict). Sequential —
    /// each parent must exist before its child. `internal` so
    /// `StartComputeApplier` (the explicit pre-warm path) shares the
    /// single source of truth for the /arc inbox tree.
    static func ensureTree(_ vos: VOSpaceBrowserService, user: String) async {
        try? await vos.createFolder(username: user, parentPath: "", folderName: ".verbinal")
        try? await vos.createFolder(username: user, parentPath: ".verbinal", folderName: "exec")
        try? await vos.createFolder(username: user, parentPath: ".verbinal/exec", folderName: "inbox")
        try? await vos.createFolder(username: user, parentPath: ".verbinal/exec", folderName: "out")
    }
}

// MARK: - run_code_output (read; polls the result file)

struct RunCodeOutputTool: AITool {
    static var verbClass: VerbClass { .read }
    static var agentSafe: Bool { true }

    /// Returns the result-file bytes, or nil when it isn't there yet
    /// (404). Injected for testing.
    let fetchOut: @Sendable (_ path: String, _ maxBytes: Int) async throws -> Data?

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
        let data = try await fetchOut(RunCodeContract.outPath(id: id), RunCodeContract.maxResultBytes)
        guard let data else {
            return Self.encode(Output(ready: false, execution_id: id,
                note: "No result yet — the compute session may still be provisioning or executing. Retry run_code_output shortly; if several polls still return nothing, the session may have stopped — call start_compute (or run_code) to (re)launch it."))
        }
        // A present-but-unparseable file means a partial/propagating write
        // (read-after-write lag on /arc) — treat as not-ready, keep polling.
        guard let result = try? JSONDecoder().decode(RunCodeContract.ResultFile.self, from: data) else {
            return Self.encode(Output(ready: false, execution_id: id,
                note: "Result file is present but not yet complete; retry shortly."))
        }
        return Self.encode(Output(
            ready: true, execution_id: id,
            status: result.status, exit_code: result.exit_code,
            stdout: result.stdout, stdout_encoding: result.stdout_encoding,
            stderr: result.stderr, stderr_encoding: result.stderr_encoding,
            duration_ms: result.duration_ms, truncated: result.truncated,
            started_at: result.started_at, finished_at: result.finished_at))
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
