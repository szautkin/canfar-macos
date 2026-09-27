// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// A mark as agents read it.
struct MarkView: Encodable, Sendable {
    let id: String
    let kind: String
    let space: String
    let x: Double?
    let y: Double?
    let raDeg: Double?
    let decDeg: Double?
    /// A cube mark's channel.
    let channel: Int?
    let halfWidth: Double?
    let halfHeight: Double?
    let text: String
    let author: String
    let colour: String
    let fontSize: Double
    let bold: Bool
    let stroke: Double
    let createdAt: String

    init(_ m: Mark) {
        let sky = m.anchor.space == .sky
        let style = m.effectiveStyle
        id = m.id
        kind = m.kind.rawValue
        space = m.anchor.space.rawValue
        x = sky ? nil : m.anchor.x
        y = sky ? nil : m.anchor.y
        raDeg = sky ? m.anchor.x : nil
        decDeg = sky ? m.anchor.y : nil
        channel = m.anchor.space == .data ? Int(m.anchor.z.rounded()) : nil
        halfWidth = m.extent?.halfWidth
        halfHeight = m.extent?.halfHeight
        text = m.text
        author = m.author.rawValue
        colour = style.colour
        fontSize = style.fontSize
        bold = style.bold
        stroke = style.stroke
        createdAt = SharedFormatters.iso8601.string(from: m.createdAt)
    }
}

/// Which viewer's marks a tool acts on.
enum MarkViewer: String, Sendable {
    case fits, cube

    static func parse(_ text: String?) throws -> MarkViewer {
        guard let text else { return .fits }
        guard let viewer = MarkViewer(rawValue: text.lowercased()) else {
            throw ToolFailureReason.invalidArgument("viewer must be fits or cube, not \"\(text)\"")
        }
        return viewer
    }
}

/// Position, size, label and style — the arguments annotate and update share.
struct MarkFields: Decodable, Sendable {
    var kind: String?
    var x: Double?
    var y: Double?
    var raDeg: Double?
    var decDeg: Double?
    var channel: Int?
    var radius: Double?
    var halfWidth: Double?
    var halfHeight: Double?
    var text: String?
    var labelOffsetX: Double?
    var labelOffsetY: Double?
    var colour: String?
    var fontSize: Double?
    var bold: Bool?
    var stroke: Double?

    /// Where a FITS mark goes.
    static let fitsPosition = #"""
            "x": { "type": "number", "description": "0-based FITS pixel column (with y)." },
            "y": { "type": "number", "description": "0-based FITS pixel row (with x)." },
            "raDeg": { "type": "number", "description": "ICRS RA in degrees (with decDeg)." },
            "decDeg": { "type": "number", "description": "ICRS Dec in degrees (with raDeg)." },
            "radius": { "type": "number", "description": "Half-size in the position's units: pixels, or degrees on the sky." },
    """#

    /// Where a cube mark goes: a voxel on a channel.
    static let cubePosition = #"""
            "x": { "type": "number", "description": "0-based voxel column." },
            "y": { "type": "number", "description": "0-based voxel row." },
            "channel": { "type": "integer", "minimum": 0, "description": "The channel the mark lives on — it is drawn on that channel's slice only." },
            "radius": { "type": "number", "description": "Half-size in voxels." },
    """#

    /// Either viewer's position, for a change.
    static let anyPosition = #"""
            "x": { "type": "number", "description": "0-based pixel (FITS) or voxel (cube) column, with y." },
            "y": { "type": "number" },
            "raDeg": { "type": "number", "description": "FITS only: ICRS RA in degrees (with decDeg)." },
            "decDeg": { "type": "number" },
            "channel": { "type": "integer", "minimum": 0, "description": "Cube only: move the mark to this channel." },
            "radius": { "type": "number", "description": "Half-size in the position's units: pixels, voxels, or degrees on the sky." },
    """#

    /// Shape, words and look — the same for both viewers.
    static let shapeProperties = #"""
            "kind": { "type": "string", "enum": ["circle", "rect", "callout", "text"], "description": "Default circle." },
            "halfWidth": { "type": "number" },
            "halfHeight": { "type": "number" },
            "text": { "type": "string", "description": "The label; required for a callout or text mark." },
            "labelOffsetX": { "type": "number", "description": "A callout label's offset from the position, in screen points." },
            "labelOffsetY": { "type": "number" },
            "colour": { "type": "string", "description": "#rrggbb." },
            "fontSize": { "type": "number", "minimum": 6, "maximum": 72 },
            "bold": { "type": "boolean" },
            "stroke": { "type": "number", "minimum": 0.5, "maximum": 20 }
    """#

    /// The position given, if one was. FITS: a pixel pair or a sky pair,
    /// never both and never half of one. Cube: a voxel on a channel —
    /// `channel` may be left out to keep `currentChannel` (a change; a
    /// change of channel alone is the caller's).
    func anchor(for viewer: MarkViewer, currentChannel: Double? = nil) throws -> Mark.Anchor? {
        switch viewer {
        case .fits:
            guard channel == nil else {
                throw ToolFailureReason.invalidArgument("channel is for cube marks — use annotate_cube, or viewer cube")
            }
            switch (x, y, raDeg, decDeg) {
            case (nil, nil, nil, nil): return nil
            case (let x?, let y?, nil, nil): return Mark.Anchor(space: .imagePixel, x: x, y: y)
            case (nil, nil, let ra?, let dec?): return Mark.Anchor(space: .sky, x: ra, y: dec)
            default: throw ToolFailureReason.invalidArgument("give the position as x and y, or as raDeg and decDeg — one pair")
            }
        case .cube:
            guard raDeg == nil, decDeg == nil else {
                throw ToolFailureReason.invalidArgument("a cube mark is on a voxel — give x, y and channel, not raDeg and decDeg")
            }
            switch (x, y) {
            case (nil, nil):
                return nil
            case (let x?, let y?):
                guard let z = channel.map(Double.init) ?? currentChannel else {
                    throw ToolFailureReason.invalidArgument("give the channel the mark lives on")
                }
                return Mark.Anchor(space: .data, x: x, y: y, z: z)
            default:
                throw ToolFailureReason.invalidArgument("give both x and y")
            }
        }
    }

    func extent() throws -> Mark.Extent? {
        if let radius {
            guard halfWidth == nil, halfHeight == nil else {
                throw ToolFailureReason.invalidArgument("give radius, or halfWidth and halfHeight — not both")
            }
            return .square(radius)
        }
        switch (halfWidth, halfHeight) {
        case (nil, nil): return nil
        case (let w?, let h?): return Mark.Extent(halfWidth: w, halfHeight: h)
        default: throw ToolFailureReason.invalidArgument("give both halfWidth and halfHeight")
        }
    }

    /// `base` with the style fields given, or nil when none were.
    func style(from base: Mark.Style) throws -> Mark.Style? {
        guard colour != nil || fontSize != nil || bold != nil || stroke != nil else { return nil }
        var style = base
        if let colour {
            guard let hex = Mark.Style.normalisedColour(colour) else {
                throw ToolFailureReason.invalidArgument("colour must be #rrggbb, not \"\(colour)\"")
            }
            style.colour = hex
        }
        if let fontSize { style.fontSize = fontSize }
        if let bold { style.bold = bold }
        if let stroke { style.stroke = stroke }
        return style.sane()
    }
}

/// What a mark tool changed.
struct MarkChange: Encodable, Sendable {
    let applied: Bool
    let file: String
    let hdu: Int?
    var mark: MarkView?
    var removed: Int?
}

/// Where a mark tool acts: a viewer (default FITS), a file (default: the
/// one on screen in that viewer) and, for FITS, an extension (default: the
/// one on screen).
struct MarkTargetArgs: Decodable, Sendable {
    var viewer: String?
    var target: String?
    var hdu: Int?
    var allHdus: Bool?
}

// MARK: - The tools

enum MarkTools {
    /// Fields and target read from the same arguments.
    struct Annotate: Decodable, Sendable {
        let fields: MarkFields
        let target: MarkTargetArgs

        init(from decoder: Decoder) throws {
            fields = try MarkFields(from: decoder)
            target = try MarkTargetArgs(from: decoder)
        }
    }

    struct Update: Decodable, Sendable {
        let id: String
        let fields: MarkFields
        let target: MarkTargetArgs

        private enum Keys: String, CodingKey { case id }
        init(from decoder: Decoder) throws {
            id = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .id)
            fields = try MarkFields(from: decoder)
            target = try MarkTargetArgs(from: decoder)
        }
    }

    struct ByID: Decodable, Sendable {
        let id: String?
        let target: MarkTargetArgs

        private enum Keys: String, CodingKey { case id }
        init(from decoder: Decoder) throws {
            id = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .id)
            target = try MarkTargetArgs(from: decoder)
        }
    }

    struct Listing: Encodable, Sendable {
        struct Entry: Encodable, Sendable {
            let hdu: Int?
            let mark: MarkView
        }
        let file: String
        let count: Int
        let marks: [Entry]
    }

    struct Exported: Encodable, Sendable {
        let format: String
        let count: Int
        let content: String
    }

    /// A FITS file and extension.
    static let targetProperties = #"""
            "target": { "type": "string", "description": "The file's path. Defaults to the file on screen." },
            "hdu": { "type": "integer", "minimum": 0, "description": "FITS only: which extension. Defaults to the one on screen." }
    """#

    /// A cube file.
    static let cubeTargetProperty = #"""
            "target": { "type": "string", "description": "The cube's path. Defaults to the cube on screen." }
    """#

    static let viewerProperty = #""viewer": { "type": "string", "enum": ["fits", "cube"], "description": "Which viewer's marks. Default fits." }"#
}

/// A mark tool: its schema and what it does. Every mark tool is a live
/// action on the screen (as on Windows), so no proposal.
struct MarkTool<Args: Decodable & Sendable, Output: Encodable & Sendable>: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    let definition: AIToolDefinition
    let run: @Sendable (Args) async throws -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        try await run(args)
    }
}

/// The read-only mark tools (listing, export).
struct MarkReadTool<Args: Decodable & Sendable, Output: Encodable & Sendable>: JSONReadTool {
    let definition: AIToolDefinition
    let run: @Sendable (Args) async throws -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        try await run(args)
    }
}
