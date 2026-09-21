// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `export_cube_figure` — the Cube Viewer's publication-figure export as a
/// tool (Windows parity). Renders the current view (slice or volume)
/// through the same annotated plate as the export sheet, using the user's
/// persisted export style, and writes a PNG to ~/Downloads.
struct ExportCubeFigureTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        /// Raster scale factor (1–4); nil defaults to 2 (the sheet's "PNG 2×").
        let scale: Double?
    }
    struct Payload: Codable, Sendable {
        let scale: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_cube_figure",
        description: "Export the Cube Viewer's current view (slice or 3D volume) as an annotated publication figure PNG in the user's Downloads folder, using the export style the user last configured. `scale` is the raster multiplier 1-4 (default 2). Requires a cube to be open; the export navigates to the Cube Viewer so the render can land. If nothing is open, call `open_cube` then `navigate_to(mode: cubeViewer)`. Proposal-gated.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "scale": {
              "type": "number",
              "minimum": 1,
              "maximum": 4,
              "description": "Raster scale factor (default 2)."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let scale = args.scale ?? 2
        guard (1...4).contains(scale) else {
            throw ToolFailureReason.invalidArgument("scale must be between 1 and 4")
        }
        return try ProposalPlan.encoding(
            kind: "export_cube_figure",
            summary: "Export the current cube view as a \(Int(scale))× figure PNG to Downloads",
            payload: Payload(scale: scale)
        )
    }
}

struct ExportCubeFigureApplier: ProposalApplier {
    let kind = "export_cube_figure"
    /// Returns the written file path.
    let run: @Sendable (_ scale: Double) async throws -> String
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ExportCubeFigureTool.Payload.self, from: proposal.payload)
        do {
            _ = try await run(payload.scale)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch let f as ToolFailureReason {
            throw ProposalApplyError.backendError("\(f)")
        } catch {
            throw ProposalApplyError.backendError("figure export failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
