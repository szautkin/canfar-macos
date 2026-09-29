// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Writes the figure an assistant asked for — `export_fits_figure` and
/// `export_cube_figure` alike — and answers with the file it wrote, which
/// before could be found only by listing Downloads (QA N8).
struct FigureExportApplier<Request: Decodable & Sendable>: ProposalApplier, ResultReportingApplier {
    let kind: String
    /// Returns the written file's path.
    let run: @Sendable (Request) async throws -> String
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let request = try JSONDecoder().decode(Request.self, from: proposal.payload)
        let path: String
        do {
            path = try await run(request)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch let f as ToolFailureReason {
            throw ProposalApplyError.backendError("\(f)")
        } catch {
            throw ProposalApplyError.backendError("figure export failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        return (try? JSONEncoder().encode(AutoAppliedAck.Extra(file: path))) ?? Data()
    }
}
