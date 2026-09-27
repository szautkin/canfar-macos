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

/// Position, size, label and style — the arguments annotate and update share.
struct MarkFields: Decodable, Sendable {
    var kind: String?
    var x: Double?
    var y: Double?
    var raDeg: Double?
    var decDeg: Double?
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

    static let schemaProperties = #"""
            "kind": { "type": "string", "enum": ["circle", "rect", "callout", "text"], "description": "Default circle." },
            "x": { "type": "number", "description": "0-based FITS pixel column (with y)." },
            "y": { "type": "number", "description": "0-based FITS pixel row (with x)." },
            "raDeg": { "type": "number", "description": "ICRS RA in degrees (with decDeg)." },
            "decDeg": { "type": "number", "description": "ICRS Dec in degrees (with raDeg)." },
            "radius": { "type": "number", "description": "Half-size in the position's units: pixels, or degrees on the sky." },
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

    /// The position given, if one was: a pixel pair or a sky pair, never both
    /// and never half of one.
    func anchor() throws -> Mark.Anchor? {
        switch (x, y, raDeg, decDeg) {
        case (nil, nil, nil, nil): return nil
        case (let x?, let y?, nil, nil): return Mark.Anchor(space: .imagePixel, x: x, y: y)
        case (nil, nil, let ra?, let dec?): return Mark.Anchor(space: .sky, x: ra, y: dec)
        default: throw ToolFailureReason.invalidArgument("give the position as x and y, or as raDeg and decDeg — one pair")
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

/// Where a mark tool acts: a file (default: the one on screen) and, for
/// FITS, an extension (default: the one on screen).
struct MarkTargetArgs: Decodable, Sendable {
    var target: String?
    var hdu: Int?
    var allHdus: Bool?
}

// MARK: - The tools

enum MarkTools {
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
        var id: String?
        var viewer: String?
        var target: String?
        var hdu: Int?
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

    static let targetProperties = #"""
            "target": { "type": "string", "description": "The file's path. Defaults to the image on screen." },
            "hdu": { "type": "integer", "minimum": 0, "description": "Which extension. Defaults to the one on screen." }
    """#

    static let viewerProperty = #""viewer": { "type": "string", "enum": ["fits"], "description": "Which viewer's marks (fits)." }"#
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
