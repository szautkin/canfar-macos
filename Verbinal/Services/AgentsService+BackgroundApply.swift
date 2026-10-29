// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Applying a pending proposal without holding the call open (plan 30).
extension AgentsService {
    /// What `start_background_apply` answered.
    struct BackgroundStart: Encodable, Sendable {
        let started: Bool
        let jobId: String?
        let kind: String?
        let summary: String?
        let status: String
        let message: String
    }

    /// Why a pending proposal may not be started in the background, or nil.
    /// The person's approval is not the agent's to give: only a kind they
    /// allow may start (plan 30 A).
    nonisolated static func backgroundRefusal(_ proposal: PendingProposal, kind: ChangeKind? = nil,
                                              permissions: ChangePermissions) -> String? {
        let decision = ChangeCatalog.decision(kind: kind ?? ChangeCatalog.kind(of: proposal), permissions: permissions)
        guard !decision.appliesAtOnce else { return nil }
        return "'\(proposal.kind)' \(decision.rule): only the person can apply it"
    }

    /// Starts applying a pending proposal without holding the call open.
    func startBackgroundApply(_ raw: String) async -> BackgroundStart {
        func refused(_ message: String) -> BackgroundStart {
            BackgroundStart(started: false, jobId: nil, kind: nil, summary: nil, status: "notStarted", message: message)
        }
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            return refused("'\(raw)' is not a proposal id — list_pending_proposals reports them")
        }
        guard let proposal = await proposals.list(origin: nil).first(where: { $0.id == id }) else {
            return refused("no pending proposal '\(raw)' — list_pending_proposals shows the ones there are")
        }
        if let why = Self.backgroundRefusal(proposal, kind: await resolveKind(proposal), permissions: permissions) {
            return refused(why)
        }
        if await proposals.state(id) == .applying {
            return refused("'\(proposal.kind)' is already being applied — follow it with get_job_status")
        }
        let jobs = applyJobs
        await jobs.start(proposal)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.applyProposalReturningResult(id, by: .background)
                await jobs.succeed(id, result: result)
            } catch {
                await jobs.fail(id, message: error.localizedDescription)
            }
        }
        return BackgroundStart(started: true, jobId: id.uuidString, kind: proposal.kind, summary: proposal.summary,
                               status: "running", message: "started; follow it with get_job_status")
    }

    /// A job's state, or — for an id that never ran as a job — what the
    /// proposal queue knows of it.
    func jobStatus(_ raw: String) async -> (job: ApplyJobRegistry.Job?, state: ProposalState)? {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (await applyJobs.job(id), await proposals.state(id))
    }
}
