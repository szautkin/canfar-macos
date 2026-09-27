// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Where remote compute stands, and the code sent to it — what the Remote
/// Compute screen shows a person.

// MARK: - get_compute_state

struct GetComputeStateTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable, Equatable {
        /// notSetUp, stopped, starting, running, stopping or failed.
        let state: String
        let configured: Bool
        /// What a session launches from and at, as configured.
        let image: String?
        let cores: Int
        let ram: Int
        let sessionId: String?
        let sessionStatus: String?
        let startedAt: String?
        let uptimeMinutes: Int?
        let note: String?
        /// What the session on the account runs and has, as list_sessions
        /// reports it — the platform can grant less than asked.
        let sessionImage: String?
        let sessionCores: String?
        let sessionRam: String?

        init(_ snapshot: ComputeSnapshot, now: Date = Date()) {
            let config = snapshot.configuration
            let session = snapshot.session
            func given(_ text: String?) -> String? {
                let trimmed = text?.trimmingCharacters(in: .whitespaces)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            state = snapshot.state.rawValue
            configured = config.isConfigured
            image = config.isConfigured ? config.image : nil
            cores = config.cores
            ram = config.ram
            sessionId = session?.id
            sessionStatus = session?.status
            startedAt = given(session?.startedTime)
            uptimeMinutes = ComputeState.uptime(startedAt: session?.startedTime, now: now).map { Int($0 / 60) }
            note = Self.note(configured: config.isConfigured, hasSession: session != nil)
            sessionImage = given(session?.containerImage)
            sessionCores = given(session?.cpuAllocated)
            sessionRam = given(session?.memoryAllocated)
        }

        private static func note(configured: Bool, hasSession: Bool) -> String? {
            switch (configured, hasSession) {
            case (true, _): return nil
            case (false, false):
                return "Not set up: a compute image is chosen in Settings ▸ Compute (open_settings section compute); the Remote Compute screen explains what it takes."
            case (false, true):
                return "Not set up in this app, but a compute session is on the person's account — left from another install or from before a reinstall, and still holding their cores. They can stop it on the Remote Compute screen, or you can propose stop_compute. Running code needs a compute image in Settings ▸ Compute first."
            }
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_compute_state",
        description: "Whether remote compute (run_code) is set up, and the state of its session on the user's CANFAR account: notSetUp, stopped, starting, running, stopping or failed — with the image and size it launches at (image, cores, ram) and, while there is a session, what it actually runs and has (sessionImage, sessionCores, sessionRam, as list_sessions reports them; the platform can grant less than asked) and how long it has been up. The same status the Remote Compute screen shows.",
        schema: #"""
        { "type": "object", "properties": {}, "additionalProperties": false }
        """#
    )

    let snapshot: @Sendable () async throws -> ComputeSnapshot

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        do {
            return Output(try await snapshot())
        } catch let reason as ToolFailureReason {
            throw reason
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
    }
}

// MARK: - list_compute_runs

struct ListComputeRunsTool: JSONReadTool {
    /// How much of each run's code is quoted; the rest is counted.
    static let previewLength = 400

    struct Args: Decodable, Sendable {
        var limit: Int?
    }

    struct Output: Encodable, Sendable {
        let total: Int
        let runs: [Entry]
    }

    struct Entry: Encodable, Sendable, Equatable {
        let executionId: String
        /// agent or user.
        let author: String
        let language: String
        let submittedAt: String
        /// running while it is out; then ok, error, timeout, noResult or notSent.
        let status: String
        let exitCode: Int?
        let durationMs: Int?
        let finishedAt: String?
        let codePreview: String
        let codeLength: Int

        init(_ run: ComputeRun) {
            let iso = ISO8601DateFormatter()
            executionId = run.id
            author = run.author.rawValue
            language = run.language
            submittedAt = iso.string(from: run.submittedAt)
            status = run.state
            exitCode = run.exitCode
            durationMs = run.durationMs
            finishedAt = run.finishedAt.map(iso.string(from:))
            codePreview = String(run.code.prefix(ListComputeRunsTool.previewLength))
            codeLength = run.code.count
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_compute_runs",
        description: "The code sent to remote compute from this app, newest first — by an assistant through run_code or by the person from the Remote Compute screen: who sent it (agent or user), the language, when, and its status (running while it is out; then ok, error, timeout, noResult or notSent), with the start of the code. Fetch a run's output with run_code_output(execution_id).",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "limit": { "type": "integer", "minimum": 1, "maximum": 50, "description": "How many (default 10)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let runs: @Sendable () async -> [ComputeRun]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let all = await runs()
        let limit = min(max(args.limit ?? 10, 1), ComputeRunStore.maxRuns)
        return Output(total: all.count, runs: all.prefix(limit).map(Entry.init))
    }
}
