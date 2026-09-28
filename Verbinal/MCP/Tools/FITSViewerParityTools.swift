// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// FITS-viewer parity tools — the interactions the control batch didn't
/// cover: HDU selection, auto-cut, the blink/compare workflow, the
/// linked-tab sync toggles, search-at-crosshair, and figure export.
/// Capability closures are injected by the app at wiring time.

// MARK: - select_hdu

/// Switch the active FITS tab to a different image HDU — the sidebar's
/// HDU list. Live-applied.
struct SelectHDUTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let hduIndex: Int
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let hduIndex: Int
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "select_hdu",
        description: "Switch the active FITS-viewer tab to a different image HDU (0-based index into the file's HDU list, as shown by `get_fits_header`'s hduIndex). Re-reads pixels, recomputes auto cuts, and re-renders — the sidebar HDU list click. Only image HDUs can be selected. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["hduIndex"],
          "properties": {
            "hduIndex": { "type": "integer", "minimum": 0 }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when the HDU switched.
    let select: @Sendable (Int) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let message = await select(args.hduIndex) {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true, hduIndex: args.hduIndex))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - fits_auto_cut

/// Recompute the display cut levels from the pixel statistics — the
/// render panel's Auto button. Live-applied.
struct FITSAutoCutTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Cuts: Sendable {
        let min: Double
        let max: Double
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let minCut: Double
        let maxCut: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "fits_auto_cut",
        description: "Recompute the active FITS tab's display cut levels from the pixel statistics and re-render — the render panel's Auto button. Returns the new cuts. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    /// nil = no image open; otherwise the applied cuts.
    let autoCut: @Sendable () async -> Cuts?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let cuts = await autoCut() else {
            return .failed(.targetNotResolved("No FITS image is open in the viewer"))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(
                applied: true, minCut: cuts.min, maxCut: cuts.max))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - start_blink

/// Start the blink/compare overlay between two FITS tabs. Live-applied.
struct StartBlinkTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var tabA: Int?
        var tabB: Int?
        var intervalSeconds: Double?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let tabA: Int
        let tabB: Int
        let alignedWithWCS: Bool
    }

    struct Started: Sendable {
        let tabA: Int
        let tabB: Int
        let alignedWithWCS: Bool
    }

    enum Result_: Sendable {
        case started(Started)
        case rejected(String)
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "start_blink",
        description: "Start the FITS viewer's blink comparison: tab B is overlaid on tab A and smoothly faded in and out so the eye catches differences (moving objects, transients). Defaults to tabs 0 and 1; both must be open (`list_open_tabs`). When both images have WCS the overlay is aligned on the sky and the view reframes to the shared field. `intervalSeconds` sets the fade period (0.5-5, default 1). Control with `set_blink`, end with `stop_blink`. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "tabA": { "type": "integer", "minimum": 0, "description": "Reference tab (default 0)." },
            "tabB": { "type": "integer", "minimum": 0, "description": "Overlay tab (default 1)." },
            "intervalSeconds": { "type": "number", "minimum": 0.5, "maximum": 5, "description": "Fade period in seconds (default 1)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let start: @Sendable (Args) async -> Result_

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let interval = args.intervalSeconds, !(0.5...5).contains(interval) {
            return .failed(.invalidArgument("intervalSeconds must be 0.5–5"))
        }
        switch await start(args) {
        case .rejected(let message):
            return .failed(.invalidArgument(message))
        case .started(let started):
            do {
                let bytes = try JSONEncoder().encode(Output(
                    applied: true, tabA: started.tabA, tabB: started.tabB,
                    alignedWithWCS: started.alignedWithWCS))
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
    }
}

// MARK: - set_blink

/// Adjust a running blink session: pause/resume, interval, or freeze on
/// one frame. Live-applied.
struct SetBlinkTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var paused: Bool?
        var intervalSeconds: Double?
        /// "a" or "b": freeze the fade fully on that image (implies pause).
        var show: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_blink",
        description: "Adjust the running blink session: `paused` pauses/resumes the fade, `intervalSeconds` (0.5-5) changes the period, `show` (\"a\" or \"b\") freezes fully on one image (implies pause — the toolbar's A/B buttons). Requires an active blink (`start_blink`). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "paused": { "type": "boolean" },
            "intervalSeconds": { "type": "number", "minimum": 0.5, "maximum": 5 },
            "show": { "type": "string", "enum": ["a", "b"] }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when applied.
    let apply: @Sendable (Args) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if args.paused == nil && args.intervalSeconds == nil && args.show == nil {
            return .failed(.invalidArgument("Nothing to do — pass paused, intervalSeconds, or show"))
        }
        if let interval = args.intervalSeconds, !(0.5...5).contains(interval) {
            return .failed(.invalidArgument("intervalSeconds must be 0.5–5"))
        }
        if let show = args.show, show != "a", show != "b" {
            return .failed(.invalidArgument("show must be \"a\" or \"b\""))
        }
        if let message = await apply(args) {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - stop_blink

struct StopBlinkTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Output: Encodable, Sendable {
        let applied: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "stop_blink",
        description: "End the blink comparison and restore tab A's pre-blink framing. No-op error if no blink is running. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when stopped.
    let stop: @Sendable () async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        if let message = await stop() {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

/// Windows canonical blink command. Legacy start/set/stop commands remain
/// registered aliases so existing macOS clients continue to work.
struct BlinkFITSTabsTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true
    struct Args: Decodable, Sendable {
        let partnerTab: Int?
        let intervalSeconds: Double?
        let action: String?
    }
    struct Output: Encodable, Sendable { let applied: Bool; let isBlinking: Bool; let paused: Bool }
    enum Outcome: Sendable { case applied(Output); case rejected(String) }
    let definition = AIToolDefinition.withStaticSchema(
        name: "blink_fits_tabs",
        description: "Control FITS tab blinking in the Windows-compatible shape. Start with partnerTab (optionally intervalSeconds); use action pause, resume, or stop. Live-applied.",
        schema: #"{"type":"object","properties":{"partnerTab":{"type":"integer","minimum":0},"intervalSeconds":{"type":"number","minimum":0.5,"maximum":5},"action":{"type":"string","enum":["start","pause","resume","stop"]}},"additionalProperties":false}"#)
    let apply: @Sendable (Args) async -> Outcome
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else { return .failed(.invalidArgument("Invalid arguments")) }
        switch await apply(args) {
        case .applied(let output):
            return (try? .data(JSONEncoder().encode(output))) ?? .failed(.backendError("encoding failed"))
        case .rejected(let message): return .failed(.invalidArgument(message))
        }
    }
}

struct SwitchFITSTabTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true
    struct Args: Decodable, Sendable { let index: Int }
    struct Output: Encodable, Sendable { let applied: Bool; let index: Int }
    let definition = AIToolDefinition.withStaticSchema(
        name: "switch_fits_tab",
        description: "Activate an open FITS Viewer tab by its 0-based index from list_open_tabs. Live-applied.",
        schema: #"{"type":"object","required":["index"],"properties":{"index":{"type":"integer","minimum":0}},"additionalProperties":false}"#)
    let apply: @Sendable (Int) async -> String?
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else { return .failed(.invalidArgument("index must be an integer")) }
        if let error = await apply(args.index) { return .failed(.invalidArgument(error)) }
        return (try? .data(JSONEncoder().encode(Output(applied: true, index: args.index)))) ?? .failed(.backendError("encoding failed"))
    }
}

// MARK: - set_tab_sync

/// Toggle the cross-tab Link Crosshair / Sync Zoom modes. Live-applied.
struct SetTabSyncTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var linkCrosshair: Bool?
        var syncZoom: Bool?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let linkCrosshair: Bool
        let syncZoom: Bool
        let usesImpreciseWCS: Bool
        /// Tabs whose image shares no sky with the active tab's; absent when none.
        let fieldsApart: [String]?
    }

    struct State: Sendable {
        let linkCrosshair: Bool
        let syncZoom: Bool
        let usesImpreciseWCS: Bool
        var fieldsApart: [String] = []
    }

    enum Result_: Sendable {
        case applied(State)
        case rejected(String)
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_tab_sync",
        description: "Toggle the FITS viewer's cross-tab sync modes — `linkCrosshair` mirrors the crosshair across tabs via WCS (enabling it norths-up unrotated tabs, like the UI toggle), `syncZoom` matches angular extent. Needs 2+ open tabs. Returns the resulting state plus `usesImpreciseWCS` (true when any tab's WCS is missing or approximate, so the sync may land off the true sky position) and, with the crosshair linked, `fieldsApart`: the tabs whose image shares no sky with the active tab's, where the crosshair has no place — tell the person. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "linkCrosshair": { "type": "boolean" },
            "syncZoom": { "type": "boolean" }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> Result_

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if args.linkCrosshair == nil && args.syncZoom == nil {
            return .failed(.invalidArgument("Nothing to do — pass linkCrosshair and/or syncZoom"))
        }
        switch await apply(args) {
        case .rejected(let message):
            return .failed(.invalidArgument(message))
        case .applied(let state):
            do {
                let bytes = try JSONEncoder().encode(Output(
                    applied: true,
                    linkCrosshair: state.linkCrosshair,
                    syncZoom: state.syncZoom,
                    usesImpreciseWCS: state.usesImpreciseWCS,
                    fieldsApart: state.fieldsApart.isEmpty ? nil : state.fieldsApart))
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
    }
}

// MARK: - search_at_crosshair

/// Search the archive at the active tab's crosshair position — the
/// render panel's "Search Here" (⌘⇧L). Live-applied.
struct SearchAtCrosshairTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Output: Encodable, Sendable {
        let applied: Bool
        let raDeg: Double
        let decDeg: Double
    }

    enum Result_: Sendable {
        case applied(raDeg: Double, decDeg: Double)
        case rejected(String)
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "search_at_crosshair",
        description: "Pre-fill the Search form with the active FITS tab's crosshair sky position and navigate to Search — the viewer's \"Search Here\" action. Requires a crosshair placed on an image with WCS (place one with `fits_goto_coordinate`). Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let run: @Sendable () async -> Result_

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        switch await run() {
        case .rejected(let message):
            return .failed(.targetNotResolved(message))
        case .applied(let ra, let dec):
            do {
                let bytes = try JSONEncoder().encode(Output(applied: true, raDeg: ra, decDeg: dec))
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
    }
}

// MARK: - export_fits_figure

/// The FITS viewer's publication-figure export as a tool — twin of
/// `export_cube_figure`, and of Windows' `export_fits_figure`.
struct ExportFITSFigureTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        var scale: Double?
        var format: String?
        var region: String?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var raDeg: Double?
        var decDeg: Double?
        var radiusDeg: Double?
        var markId: String?
        var marks: Bool?
        var annotate: Bool?
        var dark: Bool?
    }
    typealias Payload = FITSFigureRequest

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_fits_figure",
        description: "Save a publication figure of the active FITS image to the user's Downloads folder, as PNG or PDF: the picture, the marks drawn on it with their labels, the stretch and cuts it was drawn with, a colorbar, and the region's sky centre and field of view. Say which part of the image with `region`: the view on screen (the default), the whole image, a pixel box, a circle on the sky, or around a mark by its id. The style is the one the person last chose in the Export Figure sheet unless `marks`, `annotate` or `dark` say otherwise. Proposal-gated.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "scale": { "type": "number", "minimum": 1, "maximum": 4, "description": "PNG raster multiplier (default 2); a PDF is vector." },
            "format": { "type": "string", "enum": ["png", "pdf"], "description": "Default png." },
            "region": { "type": "string", "enum": ["view", "image", "box", "sky", "mark"], "description": "Default view." },
            "x": { "type": "number", "description": "region box: the 0-based FITS pixel column of its left edge." },
            "y": { "type": "number", "description": "region box: the 0-based FITS pixel row of its bottom edge." },
            "width": { "type": "number", "description": "region box: width in pixels." },
            "height": { "type": "number", "description": "region box: height in pixels." },
            "raDeg": { "type": "number", "description": "region sky: ICRS centre RA in degrees." },
            "decDeg": { "type": "number", "description": "region sky: ICRS centre Dec in degrees." },
            "radiusDeg": { "type": "number", "description": "region sky: radius in degrees." },
            "markId": { "type": "string", "description": "region mark: the mark to frame (from list_fits_annotations)." },
            "marks": { "type": "boolean", "description": "Draw the marks on the figure." },
            "annotate": { "type": "boolean", "description": "Header and legend; false gives the bare picture." },
            "dark": { "type": "boolean", "description": "Dark plate, or a light one for a journal." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let request = try Self.request(from: args)
        return try ProposalPlan.encoding(
            kind: "export_fits_figure",
            summary: "Export a \(request.format == .pdf ? "PDF" : "\(Int(request.scale))× PNG") figure of \(request.region.summary) to Downloads",
            payload: request
        )
    }

    /// The request the arguments make. Arguments for another region are
    /// refused, not ignored: a box's x under region sky means a mistake.
    static func request(from args: Args) throws -> FITSFigureRequest {
        let scale = args.scale ?? 2
        guard (1...4).contains(scale) else { throw ToolFailureReason.invalidArgument("scale must be between 1 and 4") }
        let format = try args.format.map {
            try FigureFile.Format(rawValue: $0.lowercased()).orThrow(ToolFailureReason.invalidArgument("format must be png or pdf"))
        } ?? .png

        let region: FITSFigureRegion
        switch (args.region ?? "view").lowercased() {
        case "view":
            region = .view
        case "image":
            region = .image
        case "box":
            guard let x = args.x, let y = args.y, let width = args.width, let height = args.height, width > 0, height > 0 else {
                throw ToolFailureReason.invalidArgument("region box needs x, y, width and height, with width and height above zero")
            }
            region = .box(x: x, y: y, width: width, height: height)
        case "sky":
            guard let ra = args.raDeg, let dec = args.decDeg, let radius = args.radiusDeg,
                  radius > 0, (-90...90).contains(dec) else {
                throw ToolFailureReason.invalidArgument("region sky needs raDeg, decDeg (−90…90) and a radiusDeg above zero")
            }
            region = .sky(raDeg: ra, decDeg: dec, radiusDeg: radius)
        case "mark":
            guard let id = args.markId?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
                throw ToolFailureReason.invalidArgument("region mark needs markId")
            }
            region = .mark(id: id)
        default:
            throw ToolFailureReason.invalidArgument("region must be view, image, box, sky or mark")
        }

        let boxGiven = [args.x, args.y, args.width, args.height].contains { $0 != nil }
        let skyGiven = [args.raDeg, args.decDeg, args.radiusDeg].contains { $0 != nil }
        if case .box = region {} else if boxGiven {
            throw ToolFailureReason.invalidArgument("x, y, width and height are for region box")
        }
        if case .sky = region {} else if skyGiven {
            throw ToolFailureReason.invalidArgument("raDeg, decDeg and radiusDeg are for region sky")
        }
        if case .mark = region {} else if args.markId != nil {
            throw ToolFailureReason.invalidArgument("markId is for region mark")
        }
        return FITSFigureRequest(scale: scale, format: format, region: region,
                                 marks: args.marks, annotate: args.annotate, dark: args.dark)
    }
}

struct ExportFITSFigureApplier: ProposalApplier {
    let kind = "export_fits_figure"
    /// Returns the written file path.
    let run: @Sendable (FITSFigureRequest) async throws -> String
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ExportFITSFigureTool.Payload.self, from: proposal.payload)
        do {
            _ = try await run(payload)
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
