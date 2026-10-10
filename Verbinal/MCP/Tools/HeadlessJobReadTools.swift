// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - get_headless_job (read)

struct GetHeadlessJobTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    typealias Output = ListHeadlessJobsTool.Output.Entry

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job",
        description: "Look up one headless job by its id — the batch job id that list_headless_jobs, launch_headless_job and list_job_history give (not a background apply's jobId: that is get_job_status's). Returns the same shape as `list_headless_jobs[i]`. A job CANFAR no longer lists comes from the job history, with `source: history`, `finishedAt` and any `failureReason`; unknownTarget when neither has it.",
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
    /// The job history's record of a job (plan 36 2.7): a finished job
    /// stays known after CANFAR stops listing it.
    var remembered: @Sendable (_ id: String) async -> JobRecord? = { _ in nil }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let jobs: [HeadlessJob]
        do {
            jobs = try await fetch()
        } catch {
            // A finished job's record holds while CANFAR cannot be reached.
            if let record = await remembered(args.id) { return Self.entry(from: record) }
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
        if let job = jobs.first(where: { $0.id == args.id }) {
            return ListHeadlessJobsTool.entry(from: job)
        }
        guard let record = await remembered(args.id) else {
            throw ToolFailureReason.unknownTarget(args.id)
        }
        return Self.entry(from: record)
    }

    /// A job from the history, in the listing's shape: what the platform
    /// still knew is there, what it no longer reports (the allocation, the
    /// expiry) is empty.
    static func entry(from record: JobRecord) -> Output {
        Output(
            id: record.id, name: record.name, status: record.status,
            image: record.image, imageLabel: "",
            startedTime: record.startedAt, expiresTime: "",
            memoryAllocated: "", cpuAllocated: "", gpuAllocated: "",
            phase: record.outcome == .succeeded ? "completed" : "failed",
            source: "history",
            finishedAt: ISO8601DateFormatter().string(from: record.finishedAt),
            failureReason: record.failureReason
        )
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
        /// Set when `state` is `"gone"`: what is left to read instead.
        var note: String? = nil
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job_logs",
        description: "Fetch container stdout/stderr for a headless job by id. Returns plain-text logs plus a typed `state` field (`\"ready\"` / `\"pending\"` / `\"gone\"` — CANFAR no longer lists the job: stop polling, `list_job_history` keeps what is known) and incremental-polling fields. For long jobs: poll with `since_bytes: nextOffset` from the previous response — you'll receive only the new bytes accumulated since the last call instead of the full log every time. `upToDate: true` signals \"no new output since your last poll\" so you know to pause before the next call. Omit `since_bytes` (or pass 0) to read the whole log from the beginning. `nextOffset` is the total log size on the server; pin it for the next poll. Skaha returns 404 during the Pending window — the tool surfaces `state: \"pending\"` with empty logs instead of throwing, so polling code doesn't need to special-case the error path.",
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
    /// Whether CANFAR lists the job now; nil when it cannot say.
    var isListed: @Sendable (_ id: String) async -> Bool? = { _ in nil }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let since = max(0, args.since_bytes ?? 0)
        do {
            let logs = try await fetch(args.id)
            // No logs from a job CANFAR has dropped: gone, not "ready" and empty.
            if logs.isEmpty, since == 0, await isListed(args.id) == false {
                return Output(id: args.id, logs: "", state: "gone", nextOffset: 0, returnedBytes: 0, upToDate: true,
                              note: HeadlessJobPresence.goneNote)
            }
            return Self.makeOutput(id: args.id, fullLogs: logs, since: since, state: "ready")
        } catch let net as NetworkError where Self.isPendingPodSignal(net) {
            // Pending: no log content yet. nextOffset stays at
            // 0 so the caller's next poll starts from the
            // beginning when the pod materialises. Or gone.
            let state = await HeadlessJobPresence.stateWithoutPod(args.id, isListed: isListed)
            return Output(
                id: args.id, logs: "", state: state,
                nextOffset: 0, returnedBytes: 0, upToDate: state == "gone",
                note: state == "gone" ? HeadlessJobPresence.goneNote : nil
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

// MARK: - A job without a pod: coming, or gone

/// Whether a job CANFAR has no pod for is still coming or gone (plan 30 J1).
/// Its logs and events answer 404 both while it is queued and once CANFAR
/// has dropped it; read as "pending" for ever, the documented polling loop
/// never ends.
enum HeadlessJobPresence {
    static let goneNote = "CANFAR no longer lists this job: stop polling — list_job_history keeps what is known of it"

    /// "gone" when the platform does not list it; else "pending" — listed,
    /// or it cannot say.
    static func stateWithoutPod(_ id: String, isListed: (String) async -> Bool?) async -> String {
        await isListed(id) == false ? "gone" : "pending"
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
        /// The events as the platform lists them; empty when there are none.
        let events: String
        let hasEvents: Bool
        /// `"ready"` once the K8s pod exists and events are
        /// fetchable; `"pending"` while the job is still queued
        /// at Skaha and no pod has been created yet (events are
        /// always empty in that state); `"gone"` when CANFAR no longer
        /// lists the job.
        let state: String
        /// Set when `state` is `"gone"`: what is left to read instead.
        var note: String? = nil
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_headless_job_events",
        description: "Fetch Kubernetes-level events for a headless job by id (scheduling decisions, pull errors, OOM kills, etc). Plain-text events plus a typed `state` field: `\"ready\"` when the pod exists and the body is the real event log; `\"pending\"` when the pod hasn't been created yet (Skaha returns HTTP 404 during this window — the tool catches it and surfaces a structured status so callers don't have to special-case the error); `\"gone\"` when CANFAR no longer lists the job — stop polling; `list_job_history` keeps what is known. Poll every few seconds during Pending; events arrive once K8s materialises the pod.",
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
    /// Whether CANFAR lists the job now; nil when it cannot say.
    var isListed: @Sendable (_ id: String) async -> Bool? = { _ in nil }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        do {
            let events = KubernetesEvents.text(try await fetch(args.id))
            return Output(id: args.id, events: events, hasEvents: !events.isEmpty, state: "ready")
        } catch let net as NetworkError where Self.isPendingPodSignal(net) {
            // Pod not yet created — job is still Pending at
            // Skaha. Surface a structured status instead of
            // bubbling the 404 up as a generic backend error. Or
            // gone: a job CANFAR no longer lists answers 404 for good.
            let state = await HeadlessJobPresence.stateWithoutPod(args.id, isListed: isListed)
            return Output(id: args.id, events: "", hasEvents: false, state: state,
                          note: state == "gone" ? HeadlessJobPresence.goneNote : nil)
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
