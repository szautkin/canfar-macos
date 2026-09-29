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
        var scale: Double?
        var format: String? = nil
        var marks: Bool? = nil
    }
    typealias Payload = CubeFigureRequest

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_cube_figure",
        description: "Export the Cube Viewer's current view (slice or 3D volume) as an annotated publication figure, PNG or PDF, in the user's Downloads folder, using the export style the user last configured — with the cube's marks drawn on it (on the slice, those on the channel shown) unless `marks` is false. `scale` is the PNG raster multiplier 1-4 (default 2). Requires a cube to be open; the export navigates to the Cube Viewer so the render can land. If nothing is open, call `open_cube` then `navigate_to(mode: cubeViewer)`. Proposal-gated; once applied, the answer's `file` is the path it wrote.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "scale": { "type": "number", "minimum": 1, "maximum": 4, "description": "PNG raster multiplier (default 2); a PDF is vector." },
            "format": { "type": "string", "enum": ["png", "pdf"], "description": "Default png." },
            "marks": { "type": "boolean", "description": "Draw the cube's marks on the figure." }
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
        let format = try args.format.map {
            try FigureFile.Format(rawValue: $0.lowercased()).orThrow(ToolFailureReason.invalidArgument("format must be png or pdf"))
        } ?? .png
        return try ProposalPlan.encoding(
            kind: "export_cube_figure",
            summary: "Export the current cube view as a \(format == .pdf ? "PDF" : "\(Int(scale))× PNG") figure to Downloads",
            payload: CubeFigureRequest(scale: scale, format: format, marks: args.marks)
        )
    }
}
