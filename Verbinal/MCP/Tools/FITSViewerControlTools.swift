// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// FITS-viewer control tools — read the active tab's render state, adjust
/// stretch/colormap/zoom, jump to sky coordinates, probe pixels, and manage
/// sky bookmarks. Capability closures are injected by the app at wiring
/// time; the tools themselves stay UI-framework-free.

// MARK: - get_fits_view

/// Read the active FITS-viewer tab's full render/view state.
struct GetFITSViewTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let isOpen: Bool
        let filePath: String?
        let hduIndex: Int?
        let imageWidth: Int?
        let imageHeight: Int?
        let stretch: String?
        let colormap: String?
        let minCut: Double?
        let maxCut: Double?
        let zoom: Double?
        let rotationRadians: Double?
        let crosshair: Crosshair?
        let openTabPaths: [String]
        let activeTabIndex: Int?

        /// `x`/`y` are the 0-based FITS array indices of the pixel under
        /// the crosshair — the convention `probe_fits_pixel` takes.
        struct Crosshair: Encodable, Sendable {
            let x: Int
            let y: Int
            let raDeg: Double?
            let decDeg: Double?
            let value: String
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_fits_view",
        description: "Read the active FITS-viewer tab's full render/view state: file path, HDU, image dimensions in pixels, stretch, colormap, cut levels (normalized 0-1), zoom factor, rotation (radians), crosshair position (0-based FITS array pixel, same convention as probe_fits_pixel, + RA/Dec in degrees when a WCS is present), and the list of open tabs. `openTabPaths` has one entry per tab, index-aligned with `activeTabIndex` and set_fits_view `tabIndex`. `isOpen` is false when the active tab has no loaded image.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}

// MARK: - set_fits_view

/// Adjust the active FITS-viewer tab's render parameters. Live-applied,
/// no proposal — the user sees the effect immediately.
struct SetFITSViewTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let stretch: String?
        let colormap: String?
        let minCut: Double?
        let maxCut: Double?
        let zoom: Double?
        let fitToWindow: Bool?
        let northUp: Bool?
        let tabIndex: Int?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_fits_view",
        description: "Adjust the active FITS-viewer tab's render state. All fields are optional; provide only what should change. Cut levels are normalized 0-1, zoom is a magnification factor (1 = 100%). Pass `tabIndex` to switch the active tab before applying. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "stretch":     { "type": "string", "enum": ["linear", "log", "sqrt", "squared", "asinh"], "description": "Intensity stretch function." },
            "colormap":    { "type": "string", "enum": ["grayscale", "inverted", "heat", "cool", "viridis", "inferno", "magma", "plasma"], "description": "Colormap name." },
            "minCut":      { "type": "number", "minimum": 0, "maximum": 1, "description": "Lower cut level, normalized 0-1." },
            "maxCut":      { "type": "number", "minimum": 0, "maximum": 1, "description": "Upper cut level, normalized 0-1." },
            "zoom":        { "type": "number", "exclusiveMinimum": 0, "description": "Magnification factor (1 = 100%)." },
            "fitToWindow": { "type": "boolean", "description": "Fit the image to the window (overrides zoom)." },
            "northUp":     { "type": "boolean", "description": "Rotate the view so north is up (requires a WCS solution)." },
            "tabIndex":    { "type": "integer", "minimum": 0, "description": "Switch to this open tab (0-based) before applying." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when applied cleanly.
    let apply: @Sendable (Args) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let message = await apply(args) {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true, message: nil))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - fits_goto_coordinate

/// Center the active FITS view on a sky coordinate and place the
/// crosshair there. Requires an open image with a WCS solution.
struct FITSGotoCoordinateTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let raDeg: Double
        let decDeg: Double
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let onImage: Bool
        let message: String?
        /// 0-based FITS pixel the position maps to, when it has one.
        var pixelX: Double? = nil
        var pixelY: Double? = nil
    }

    /// What the viewer's Go To came to, as the tool reports it.
    enum Result: Sendable {
        case centred
        case offImage(x: Double, y: Double, whereItFalls: String)
        case unplaceable
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "fits_goto_coordinate",
        description: "Center the active FITS view on (RA, Dec) in degrees and place the crosshair there — the viewer's Go To, with the same answer. Requires an open image with a WCS solution. Off the image the view does not move and the reply says `onImage: false`, where the position falls (e.g. \"320 px left of the image\") and its pixel. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["raDeg", "decDeg"],
          "properties": {
            "raDeg":  { "type": "number", "minimum": 0,   "exclusiveMaximum": 360 },
            "decDeg": { "type": "number", "minimum": -90, "maximum": 90 }
          },
          "additionalProperties": false
        }
        """#
    )

    /// nil = no image with a WCS is open.
    let goTo: @Sendable (Double, Double) async -> Result?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        guard let result = await goTo(args.raDeg, args.decDeg) else {
            return .failed(.targetNotResolved("No FITS image with a WCS solution is open"))
        }
        let position = String(format: "(%.4f, %.4f)", args.raDeg, args.decDeg)
        let body: Output
        switch result {
        case .centred:
            body = Output(applied: true, onImage: true, message: nil)
        case .offImage(let x, let y, let whereItFalls):
            body = Output(applied: false, onImage: false,
                          message: "\(position) falls \(whereItFalls); view not moved.",
                          pixelX: x, pixelY: y)
        case .unplaceable:
            body = Output(applied: false, onImage: false,
                          message: "\(position) has no pixel on this image (the far side of its projection); view not moved.")
        }
        do {
            return .data(try JSONEncoder().encode(body))
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - probe_fits_pixel

/// Read one pixel of the active FITS image: its value plus the RA/Dec it
/// maps to when a WCS is present.
struct ProbeFITSPixelTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let x: Int
        let y: Int
    }

    struct Output: Encodable, Sendable {
        let x: Int
        let y: Int
        let value: Double?
        let raDeg: Double?
        let decDeg: Double?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "probe_fits_pixel",
        description: "Read one pixel of the active FITS image by 0-based FITS array coordinate (same convention as astropy all_pix2world origin=0). x is the column, y is the stored image row (y=0 is the first row in the file, not the top of the displayed canvas). Returns the pixel value (nil for blank/NaN) and RA/Dec in degrees when a WCS solution is present. Out-of-bounds coordinates fail.",
        schema: #"""
        {
          "type": "object",
          "required": ["x", "y"],
          "properties": {
            "x": { "type": "integer", "minimum": 0, "description": "0-based FITS array column (NAXIS1)." },
            "y": { "type": "integer", "minimum": 0, "description": "0-based FITS array row (NAXIS2); y=0 is the first stored row." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// The wiring closure throws `ToolFailureReason.targetNotResolved`
    /// when no FITS image is open; `handle` forwards it as-is so the
    /// agent gets the typed failure.
    let probe: @Sendable (Int, Int) async throws -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        try await probe(args.x, args.y)
    }
}

// MARK: - list_fits_bookmarks

/// List the user's saved sky bookmarks.
struct ListFITSBookmarksTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let entries: [Entry]
    }

    struct Entry: Encodable, Sendable {
        let id: String
        let label: String
        let raDeg: Double
        let decDeg: Double
        let sourceFilePath: String
        let savedAtISO: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_fits_bookmarks",
        description: "List saved sky bookmarks (id, label, RA/Dec in degrees, source FITS file path, savedAt). Use the id with `delete_fits_bookmark` and the coordinates with `fits_goto_coordinate`.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [Entry]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        Output(entries: await snapshot())
    }
}

// MARK: - save_fits_bookmark

/// Save a labelled sky bookmark at a coordinate.
struct SaveFITSBookmarkTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let label: String
        let raDeg: Double
        let decDeg: Double
    }

    /// Encoded as the proposal payload; the applier reads it back.
    struct Payload: Codable, Sendable {
        let label: String
        let raDeg: Double
        let decDeg: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "save_fits_bookmark",
        description: "Save a labelled sky bookmark at (RA, Dec) in degrees (RA 0-360, Dec -90 to 90).",
        schema: #"""
        {
          "type": "object",
          "required": ["label", "raDeg", "decDeg"],
          "properties": {
            "label":  { "type": "string", "minLength": 1 },
            "raDeg":  { "type": "number", "minimum": 0,   "exclusiveMaximum": 360 },
            "decDeg": { "type": "number", "minimum": -90, "maximum": 90 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.label.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailureReason.invalidArgument("label is empty")
        }
        guard args.raDeg >= 0, args.raDeg < 360 else {
            throw ToolFailureReason.invalidArgument("raDeg must be in 0..<360")
        }
        guard args.decDeg >= -90, args.decDeg <= 90 else {
            throw ToolFailureReason.invalidArgument("decDeg must be in -90...90")
        }
        return try ProposalPlan.encoding(
            kind: "save_fits_bookmark",
            summary: String(
                format: "Save sky bookmark '%@' at (%.4f, %.4f)",
                args.label, args.raDeg, args.decDeg
            ),
            payload: Payload(label: args.label, raDeg: args.raDeg, decDeg: args.decDeg)
        )
    }
}

// MARK: - delete_fits_bookmark (destructive)

struct DeleteFITSBookmarkTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Payload: Codable, Sendable {
        let id: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_fits_bookmark",
        description: "Permanently delete a saved sky bookmark by id.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string", "description": "UUID string of the bookmark." } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        return try ProposalPlan.encoding(
            kind: "delete_fits_bookmark",
            summary: "Delete sky bookmark \(args.id)",
            payload: Payload(id: args.id)
        )
    }
}

// MARK: - list_open_tabs

/// List the viewer documents currently open: FITS and Cube viewer tabs.
struct ListOpenTabsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let fitsTabs: [Tab]
        let activeFITSTabIndex: Int?
        let cubeOpen: Bool
        let cubeFileName: String?
        let cubeTabs: [Tab]
        let activeCubeTabIndex: Int?

        struct Tab: Encodable, Sendable {
            let index: Int
            let path: String
            let isActive: Bool
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_open_tabs",
        description: "List open viewer documents: FITS and Cube Viewer tabs (0-based index, path, active flag), plus active document summaries.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}


// MARK: - Appliers

/// Concrete handler that runs when the user clicks Apply on a
/// `save_fits_bookmark` proposal in the strip (or immediately when
/// auto-apply is on).
struct SaveFITSBookmarkApplier: ProposalApplier {
    let kind = "save_fits_bookmark"
    let save: @Sendable (String, Double, Double, AgentAttribution) async -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(SaveFITSBookmarkTool.Payload.self, from: proposal.payload)
        await save(payload.label, payload.raDeg, payload.decDeg,
                   AgentAttribution.from(proposal: proposal))
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}

struct DeleteFITSBookmarkApplier: ProposalApplier {
    let kind = "delete_fits_bookmark"
    let delete: @Sendable (String) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteFITSBookmarkTool.Payload.self, from: proposal.payload)
        try await delete(payload.id)
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
