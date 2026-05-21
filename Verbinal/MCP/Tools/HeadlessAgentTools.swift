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
        /// Inline Python source to run in the container. When set,
        /// the tool hex-encodes the source server-side and rewrites
        /// `cmd` + `args` + `env` to invoke a bytes-from-hex decoder
        /// — so the agent writes plain Python and never has to
        /// know about Skaha's `=`/`&`/`"`/`$`/newline quirks.
        /// Mutually exclusive with caller-supplied `cmd`/`args`.
        var script: String?
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
        /// Raw Python source the applier should upload to VOSpace
        /// before launching. Set by `plan()` when the inline
        /// `script` parameter overflowed the 2 KB hex-env cap;
        /// `nil` for direct cmd/args launches and for hex-inline
        /// scripts that fit. The applier writes it to
        /// `~/.verbinal-scripts/<sha>.py`, rewrites `cmd: "python3"`
        /// + `args: <staged-path>`, then proceeds. Keeps the
        /// "I write Python, the platform handles transport"
        /// experience intact regardless of source length.
        let pendingScriptUpload: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "launch_headless_job",
        description: "Launch one or more replicas of a headless Skaha batch job. The `image` MUST be a value returned by `list_session_images` filtered to `type: \"headless\"` — hand-typed strings will fail with HTTP 400 'unknown or private image'. BEFORE picking an image when the user has specific package or capability needs (astropy ≥6, fitsio, photutils, R, CUDA, …), call `find_images_with_packages(...)` first — the platform already knows what's installed in most catalogue images; package-by-name lookup beats picking by image name and discovering missing deps after the job runs. RECOMMENDED for Python work: pass your source as the `script` parameter (any length up to 1 MB). For source ≤ ~1 KB the tool hex-encodes inline; for anything larger the applier auto-stages the source to `~/.verbinal-scripts/<hash>.py` in VOSpace and rewrites cmd/args to invoke the staged file — the agent never has to know which path ran. All the Skaha env quirks (`=`, `&`, `\"`, `$`, newline, 2 KB cap) become invisible to the caller either way. For non-Python or direct-binary work use `cmd`+`args` instead (mutually exclusive with `script`). `cmd` is the binary; `args` is a SINGLE space-separated string Skaha tokenises server-side. `env` is an ordered array of {key, value} pairs — REPLICA_ID and REPLICA_COUNT auto-injected. `replicas` ≥ 2 spawns N parallel containers suffixed `-1, -2, …`. Returns the launched job id(s); partial-replica failure surfaces as backendError with the count that DID land. SCHEDULING — read this BEFORE picking sizes. THE DEFAULT IS 1 CPU / 1 GB RAM / 0 GPU. Omitting `cores`/`ram`/`gpus` ⇒ the tool forces 1/1/0 — the smallest schedulable shape on the CANFAR cluster, which almost always lands on a warm node in <60s. Do NOT pad upward unless you have an empirical reason: 2c/8g and above frequently sit in Pending 15+ minutes (sometimes hours) under shared-cluster pressure, and the proposal summary will surface a SCHEDULING WARNING the user has to approve. For smoke tests, first runs, parameter sweeps, package probing, and any iterative work — keep the defaults. Only ask for more when a previous 1c/1g run actually OOMed or wallclocked out; estimating memory needs in advance is almost always wrong and trades real wall-clock latency for imagined headroom. GPUs are scarce and queue indefinitely on most images — pass `gpus: 1` only when the image is GPU-typed (check `list_session_images` capabilities) AND the workload is genuinely CUDA-bound. SKAHA ENV QUIRKS (rejected by the client validator before send so you get a typed error instead of a silent drop): values cannot contain `=` anywhere (every Python script trips this; use `script`), `&` (numpy `a & b` → use `np.logical_and`), newlines, or exceed 2 KB. Also documented but caller-discipline: `$VAR` is shell-expanded server-side (pass `\\$VAR` for literal), embedded `\"` can corrupt encoding.",
        schema: #"""
        {
          "type": "object",
          "required": ["name", "image"],
          "properties": {
            "name":     { "type": "string", "minLength": 1 },
            "image":    { "type": "string", "minLength": 1 },
            "cmd":      { "type": "string" },
            "args":     { "type": "string" },
            "script":   { "type": "string", "description": "Inline Python source; hex-encoded server-side. Mutually exclusive with cmd/args." },
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
            "cores":    { "type": "integer", "minimum": 1, "description": "CPU cores. DEFAULT IF OMITTED: 1 (tool-forced; not Skaha's 2). Anything >1 surfaces a scheduling warning and often sits in Pending 15+ min." },
            "ram":      { "type": "integer", "minimum": 1, "description": "RAM in GB. DEFAULT IF OMITTED: 1 (tool-forced; not Skaha's 8). Anything >1 surfaces a scheduling warning and often sits in Pending 15+ min." },
            "gpus":     { "type": "integer", "minimum": 0, "description": "GPU count. DEFAULT IF OMITTED: 0. Non-zero asks queue indefinitely on most images; only use with GPU-typed images for genuinely CUDA-bound workloads." },
            "replicas": { "type": "integer", "minimum": 1, "maximum": 50 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let replicas = max(1, args.replicas ?? 1)
        var env = args.env ?? []
        var cmd = args.cmd
        var cliArgs = args.args

        // Inline `script` parameter has two paths depending on
        // size. Small enough to fit in a hex-encoded env value
        // (≤ 2 KB hex ≈ 1 KB Python source) → hex-encode and
        // inject the decoder shim, all server-side; the env
        // round-trip stays transparent. Larger than that →
        // defer to the applier, which uploads the source to
        // VOSpace under the user's `~/.verbinal-scripts/`
        // directory and rewrites cmd/args to invoke the
        // uploaded file. Either way the agent writes plain
        // Python; the size question is invisible.
        // (Mutually exclusive with hand-rolled cmd/args.)
        var pendingScriptUpload: String? = nil
        if let script = args.script {
            if cmd != nil || cliArgs != nil {
                throw ToolFailureReason.invalidArgument(
                    "`script` is mutually exclusive with `cmd`/`args` — pick one"
                )
            }
            // 1 MB hard cap — beyond that the user should be using
            // `upload_text_to_vospace` directly with a meaningful
            // filename, not relying on the auto-stage path that
            // hashes-and-hides the script under
            // `.verbinal-scripts/<sha>.py`.
            let maxScriptBytes = 1024 * 1024
            if script.utf8.count > maxScriptBytes {
                throw ToolFailureReason.invalidArgument(
                    "`script` is \(script.utf8.count) bytes; the inline-script auto-upload path caps at 1 MB. Use `upload_text_to_vospace` with an explicit filename, then launch with `cmd: \"python3\", args: \"/arc/home/.../your-script.py\"`."
                )
            }
            let hex = Self.hexEncode(script)
            if hex.utf8.count <= 2048 {
                // Fits in env — use the in-band path.
                let envKey = "VERBINAL_SCRIPT"
                cmd = "python3"
                cliArgs = "-c exec(bytes.fromhex(__import__('os').environ['\(envKey)']).decode())"
                env.append(AgentEnvVar(key: envKey, value: hex))
            } else {
                // Overflow — applier will upload and rewrite.
                // We leave cmd/args nil here; the applier
                // populates them after the upload completes.
                pendingScriptUpload = script
            }
        }
        try Self.validateEnv(env)

        // Force the smallest schedulable shape (1c/1g/0gpu) when
        // the caller omits any dimension. Skaha's server-side
        // default is 2c/8g/0gpu, which under current CANFAR
        // cluster pressure routinely sits in Pending 15+ minutes
        // before placement. 1c/1g almost always lands on a warm
        // node in under a minute — the right default for the
        // overwhelming majority of jobs (smoke tests, parameter
        // sweeps, light analysis). Callers who genuinely need
        // more must request it explicitly; we surface a warning
        // in the summary so the human approver can catch
        // accidental over-asks.
        let effectiveCores = args.cores ?? 1
        let effectiveRam   = args.ram   ?? 1
        let effectiveGpus  = args.gpus  ?? 0

        let payload = Payload(
            name: args.name, image: args.image,
            cmd: cmd, args: cliArgs, env: env,
            cores: effectiveCores, ram: effectiveRam, gpus: effectiveGpus,
            replicas: replicas,
            pendingScriptUpload: pendingScriptUpload
        )
        let oversized = effectiveCores > 1 || effectiveRam > 1 || effectiveGpus > 0
        let warning = oversized
            ? " ⚠ SCHEDULING WARNING: \(effectiveCores)c/\(effectiveRam)g/\(effectiveGpus)gpu often sits in Pending 15+ min on the shared cluster; use 1c/1g/0gpu for first runs and smoke tests."
            : ""
        let summary: String
        if replicas == 1 {
            summary = "Launch headless job '\(args.name)' — image: \(args.image) (\(effectiveCores)c/\(effectiveRam)g/\(effectiveGpus)gpu)\(warning)"
        } else {
            summary = "Launch \(replicas) headless replicas of '\(args.name)' — image: \(args.image) (\(effectiveCores)c/\(effectiveRam)g/\(effectiveGpus)gpu each)\(warning)"
        }
        return try ProposalPlan.encoding(
            kind: "launch_headless_job",
            summary: summary,
            payload: payload
        )
    }

    // MARK: - Env validation

    /// Reject env values that hit any of Skaha's known server-side
    /// parser bugs *before* the request leaves the client, so the
    /// agent sees a typed `invalidArgument` instead of a silent
    /// truncation, an executor `KeyError`, or worse — a job that
    /// runs with mis-parsed arguments and produces garbage results.
    ///
    /// Each rule encodes a quirk we've directly observed:
    ///
    ///   * **Length**: env values over ~2 KB get silently dropped
    ///     somewhere between the form encoder and Kubernetes. The
    ///     2026-05-13 QA pass measured 14-byte values passing and
    ///     ~3.5 KB values vanishing; we cap at 2 KB to keep a
    ///     comfortable margin under Skaha's actual (undocumented)
    ///     threshold.
    ///   * **`&` character**: Skaha appears to re-form-decode once
    ///     server-side, so a literal `&` in the value reads as a
    ///     field separator and everything after is dropped.
    ///     Percent-encoding at the client doesn't help. Common in
    ///     numpy boolean-AND expressions; rewrite as
    ///     `np.logical_and(...)`.
    ///   * **`$VAR`** / **`"`** / trailing `=`: already documented
    ///     in the tool description; we don't reject these (legitimate
    ///     uses exist for `$` in shell-evaluated values) but the
    ///     description tells callers to escape or substitute.
    ///
    /// REPLICA_ID / REPLICA_COUNT are auto-injected and bypass this
    /// validator (they're integers, no quirks possible).
    static func validateEnv(_ env: [AgentEnvVar]) throws {
        let maxValueBytes = 2048
        for pair in env {
            let valueBytes = pair.value.utf8.count
            if valueBytes > maxValueBytes {
                throw ToolFailureReason.invalidArgument(
                    "env value for key '\(pair.key)' is \(valueBytes) bytes; Skaha silently drops values larger than ~2 KB. Pass the source as the `script` parameter (which hex-encodes server-side) or stage the payload via VOSpace / a file inside the image."
                )
            }
            if pair.value.contains("&") {
                throw ToolFailureReason.invalidArgument(
                    "env value for key '\(pair.key)' contains an unescaped '&' character. Skaha's server-side form parser misreads it as a field separator and drops everything after. Common cause: numpy boolean-AND in a Python heredoc — substitute `np.logical_and(a, b)` for `a & b`, or pass the source via the `script` parameter which hex-encodes around all five quirks."
                )
            }
            // 2026-05-13 QA finding F-2026-05-13-B: an `=` *anywhere*
            // in the env value silently drops the entire variable
            // server-side, not just a trailing `=` as the earlier
            // tool description claimed. Confirmed by isolated probe
            // jobs `lr5lzbpq` (value `a=1\nb=2` → MISSING) and
            // `vf3yad27` (value `abc=xyz` → MISSING). Every real
            // Python script contains `=` (assignment, comparison,
            // kwargs), so the documented "pass script via env" path
            // is unusable for real workloads without an encoding
            // shim. Reject here so the agent doesn't burn a job
            // discovering this manually.
            if pair.value.contains("=") {
                throw ToolFailureReason.invalidArgument(
                    "env value for key '\(pair.key)' contains '='. Skaha silently drops env values containing '=' anywhere (not just trailing) — every real Python script trips this. Pass the source as the `script` parameter on this tool, which hex-encodes around the bug; or, for shorter values, substitute `=` with another delimiter and split inside the container."
                )
            }
            if pair.value.contains("\n") {
                throw ToolFailureReason.invalidArgument(
                    "env value for key '\(pair.key)' contains a newline. Skaha's form parser terminates the value at the first newline. Use the `script` parameter for multi-line code, or join with `\\n` literals if the value is data."
                )
            }
        }
    }

    /// Hex-encode a UTF-8 string as a continuous `[0-9a-f]+`
    /// sequence. The output alphabet contains none of Skaha's
    /// problem characters (`=`, `&`, `"`, `$`, newline), so a
    /// hex-encoded payload survives transit verbatim. Container
    /// decodes back with `bytes.fromhex(...).decode()` — see the
    /// `script` parameter wiring on `launch_headless_job`.
    static func hexEncode(_ s: String) -> String {
        s.utf8.map { String(format: "%02x", $0) }.joined()
    }
}

struct LaunchHeadlessJobApplier: ProposalApplier {
    let kind = "launch_headless_job"
    let service: HeadlessService
    let recentLaunchStore: RecentLaunchStore
    let activity: AgentActivityStore
    /// VOSpace handle for the auto-script-stage path. Optional —
    /// instances built before the auto-stage feature shipped (or
    /// in tests that don't need it) can leave it `nil` and just
    /// won't support `pendingScriptUpload` payloads.
    let vospace: VOSpaceBrowserService?
    /// Username resolver, MainActor-hopped. Used by the auto-
    /// stage path to build the VOSpace target path.
    let username: (@Sendable () async -> String)?

    func apply(_ proposal: PendingProposal) async throws {
        var payload = try JSONDecoder().decode(LaunchHeadlessJobTool.Payload.self, from: proposal.payload)

        // Auto-stage long scripts to VOSpace. The `script` plan
        // step decided this couldn't fit in the env (>2 KB hex);
        // upload it now under a deterministic content-addressed
        // path so repeated identical scripts don't pile up
        // garbage in the user's storage. Rewrites cmd/args to
        // invoke the staged file.
        if let source = payload.pendingScriptUpload {
            guard let vospace, let username else {
                throw ProposalApplyError.backendError(
                    "auto-stage requires VOSpace; the applier was built without one — fallback: pass cmd/args directly to `launch_headless_job`"
                )
            }
            let user = await username()
            guard !user.isEmpty else {
                throw ProposalApplyError.backendError("auto-stage needs a username; user is not authenticated")
            }
            let hashHex = Self.shortHash(source)
            let folderPath = ".verbinal-scripts"
            let filename = "\(hashHex).py"
            // Make the parent folder idempotently — Skaha returns
            // a benign error if it already exists.
            _ = try? await vospace.createFolder(
                username: user,
                parentPath: "",
                folderName: folderPath
            )
            let stagingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("verbinal-script-\(UUID().uuidString).py")
            guard let data = source.data(using: .utf8) else {
                throw ProposalApplyError.backendError("could not encode script as UTF-8 for staging")
            }
            do {
                try data.write(to: stagingURL, options: .atomic)
            } catch {
                throw ProposalApplyError.backendError("could not stage script to temp file: \(error.localizedDescription)")
            }
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            do {
                try await withApplierTimeout(seconds: 120, label: "auto-stage script") {
                    try await vospace.uploadFile(
                        username: user,
                        remotePath: "\(folderPath)/\(filename)",
                        fileURL: stagingURL
                    )
                }
            } catch let pa as ProposalApplyError {
                throw pa
            } catch {
                throw ProposalApplyError.backendError("auto-stage upload failed: \(error.localizedDescription)")
            }
            let containerPath = "/arc/home/\(user)/\(folderPath)/\(filename)"
            // Rebuild the payload with the staged-script cmd/args
            // and clear the upload marker so a hypothetical
            // re-apply (e.g. user dragged from the strip) doesn't
            // re-upload the same content.
            payload = LaunchHeadlessJobTool.Payload(
                name: payload.name, image: payload.image,
                cmd: "python3", args: containerPath,
                env: payload.env,
                cores: payload.cores, ram: payload.ram, gpus: payload.gpus,
                replicas: payload.replicas,
                pendingScriptUpload: nil
            )
        }

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

    /// 12-hex-char content-address derived from the script
    /// source. Stable per source string so retries / re-runs of
    /// identical content reuse the staged file in VOSpace
    /// (`.verbinal-scripts/<hash>.py`) rather than pile up
    /// duplicates.
    private static func shortHash(_ s: String) -> String {
        var hasher = Hasher()
        hasher.combine(s)
        let value = UInt64(bitPattern: Int64(hasher.finalize()))
        return String(format: "%012x", value & 0xFFFFFFFFFFFF)
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
    // The 2026-05-15 QA report named this tool as the recurring
    // 5-minute hang on the MCP transport. 30s is enough for a
    // healthy Skaha to return; past that the agent should see a
    // typed deadline error and decide whether to retry or move
    // on, not sit in `try await` indefinitely.
    var toolTimeoutSeconds: TimeInterval { 30 }
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
        /// Byte offset to start returning from. Pass back the
        /// previous response's `nextOffset` to receive only the
        /// new bytes accumulated since last poll — agents
        /// running a long job poll for progress without
        /// re-receiving the same content each time. Omit (or
        /// pass 0) to read the whole log.
        var since_bytes: Int?
    }

    /// Logs payload + typed lifecycle indicator. Same shape as
    /// `GetHeadlessJobEventsTool.Output` — both endpoints depend
    /// on the K8s pod existing; during Pending neither can
    /// produce content and Skaha returns 404. Surfacing this as
    /// a structured `state: "pending"` instead of throwing a
    /// generic backendError lets callers poll without
    /// special-casing the error path.
    struct Output: Encodable, Sendable {
        let id: String
        let logs: String
        /// `"ready"` when the pod exists and `logs` is the real
        /// content; `"pending"` while the job is queued at Skaha
        /// and no pod has been created.
        let state: String
        /// Total log size on the server, in bytes. Same value
        /// across calls until the job emits more output. Pass
        /// this back as `since_bytes` on the next poll to
        /// receive only the delta.
        let nextOffset: Int
        /// Bytes returned in this response (the suffix length).
        /// Equals `nextOffset - max(0, args.since_bytes ?? 0)`
        /// on a successful read.
        let returnedBytes: Int
        /// `true` when the caller's `since_bytes` was past the
        /// current end of the log (e.g. poll happened before
        /// new output arrived). `logs` is empty in that case
        /// and the agent should pause before polling again.
        let upToDate: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job_logs",
        description: "Fetch container stdout/stderr for a headless job by id. Returns plain-text logs plus a typed `state` field (`\"ready\"` / `\"pending\"`) and incremental-polling fields. For long jobs: poll with `since_bytes: nextOffset` from the previous response — you'll receive only the new bytes accumulated since the last call instead of the full log every time. `upToDate: true` signals \"no new output since your last poll\" so you know to pause before the next call. Omit `since_bytes` (or pass 0) to read the whole log from the beginning. `nextOffset` is the total log size on the server; pin it for the next poll. Skaha returns 404 during the Pending window — the tool surfaces `state: \"pending\"` with empty logs instead of throwing, so polling code doesn't need to special-case the error path.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id":          { "type": "string" },
            "since_bytes": { "type": "integer", "minimum": 0, "description": "Byte offset to start from. Pass back the previous call's nextOffset for incremental polling." }
          },
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable (_ id: String) async throws -> String

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let since = max(0, args.since_bytes ?? 0)
        do {
            let logs = try await fetch(args.id)
            return Self.makeOutput(id: args.id, fullLogs: logs, since: since, state: "ready")
        } catch let net as NetworkError where Self.isPendingPodSignal(net) {
            // Pending: no log content yet. nextOffset stays at
            // 0 so the caller's next poll starts from the
            // beginning when the pod materialises.
            return Output(
                id: args.id, logs: "", state: "pending",
                nextOffset: 0, returnedBytes: 0, upToDate: false
            )
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
    }

    /// Slice `fullLogs` from byte `since` and build the
    /// response envelope. Pulled out as a static so the tests
    /// can exercise the slicing math without running the fetch
    /// closure.
    ///
    /// Uses UTF-8 byte indexing — Swift `String` is UTF-8
    /// backed so `.utf8.count` is the byte length. When
    /// `since` lands in the middle of a multi-byte codepoint
    /// the leading partial bytes decode as the replacement
    /// character; acceptable for log streams (overwhelmingly
    /// ASCII with rare unicode) and avoids the round-up
    /// complexity that would otherwise leak bytes the agent
    /// already saw.
    static func makeOutput(
        id: String, fullLogs: String, since: Int, state: String
    ) -> Output {
        let bytes = Array(fullLogs.utf8)
        let total = bytes.count
        let clampedSince = min(max(since, 0), total)
        let suffixBytes = bytes[clampedSince..<total]
        let suffix = String(decoding: suffixBytes, as: UTF8.self)
        return Output(
            id: id,
            logs: suffix,
            state: state,
            nextOffset: total,
            returnedBytes: total - clampedSince,
            upToDate: since >= total
        )
    }

    private static func isPendingPodSignal(_ error: NetworkError) -> Bool {
        guard case .httpError(let code, _) = error, code == 404 else { return false }
        return true
    }
}

// MARK: - get_headless_job_events (read)

struct GetHeadlessJobEventsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    /// Event payload plus a typed lifecycle indicator. The
    /// indicator distinguishes "events are real and empty" from
    /// "K8s hasn't materialised the pod yet so there's nothing
    /// to fetch" — previously the same observable shape, an empty
    /// string or a 404, with no way for the caller to know which
    /// case they were in (F-2026-05-13-C from the 2026-05-13 QA
    /// report).
    struct Output: Encodable, Sendable {
        let id: String
        let events: String
        /// `"ready"` once the K8s pod exists and events are
        /// fetchable; `"pending"` while the job is still queued
        /// at Skaha and no pod has been created yet (events are
        /// always empty in that state).
        let state: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job_events",
        description: "Fetch Kubernetes-level events for a headless job by id (scheduling decisions, pull errors, OOM kills, etc). Plain-text events plus a typed `state` field: `\"ready\"` when the pod exists and the body is the real event log; `\"pending\"` when the pod hasn't been created yet (Skaha returns HTTP 404 during this window — the tool catches it and surfaces a structured status so callers don't have to special-case the error). Poll every few seconds during Pending; events arrive once K8s materialises the pod.",
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
            return Output(id: args.id, events: events, state: "ready")
        } catch let net as NetworkError where Self.isPendingPodSignal(net) {
            // Pod not yet created — job is still Pending at
            // Skaha. Surface a structured status instead of
            // bubbling the 404 up as a generic backend error.
            return Output(id: args.id, events: "", state: "pending")
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
    }

    /// 404 + a body mentioning "not found" is Skaha's signal
    /// that no K8s pod exists yet. Any other 404 (or status) is
    /// a real error we should propagate.
    private static func isPendingPodSignal(_ error: NetworkError) -> Bool {
        guard case .httpError(let code, _) = error, code == 404 else { return false }
        return true
    }
}
