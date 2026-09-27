// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A mark on a viewer — a circle or box round a source, a callout with a
/// leader to its label, or a label alone. One model for the FITS image and
/// the cube: only how a position becomes a point on screen differs, and
/// the viewer supplies that (`MarkProjection`).
struct Mark: Codable, Identifiable, Equatable, Sendable {

    enum Kind: String, Codable, CaseIterable, Sendable {
        case circle, rect, callout, text

        var needsExtent: Bool { self == .circle || self == .rect }

        /// The words people use for each.
        static func parse(_ text: String?) -> Kind? {
            switch text?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "circle", "ellipse": return .circle
            case "rect", "rectangle", "box", "square": return .rect
            case "callout", "label", "leader": return .callout
            case "text", "note": return .text
            default: return nil
            }
        }
    }

    /// Where a mark is pinned — never in screen pixels, which slide off the
    /// subject at the first pan.
    struct Anchor: Codable, Equatable, Sendable {
        enum Space: String, Codable, Sendable {
            /// 0-based FITS array pixels.
            case imagePixel
            /// ICRS degrees — the same place in another image of the field.
            case sky
            /// Cube voxels (x, y, channel).
            case data
        }

        var space: Space
        var x: Double
        var y: Double
        var z: Double = 0

        /// A NaN draws nothing and reports nothing, and a Dec of 120° is not
        /// a place: refused rather than drawn somewhere.
        var isValid: Bool {
            guard x.isFinite, y.isFinite, z.isFinite else { return false }
            return space != .sky || ((0..<360).contains(x) && (-90...90).contains(y))
        }
    }

    /// Half-sizes in the anchor's own units (pixels, or degrees on the sky),
    /// so a mark keeps its size on the subject as the view zooms.
    struct Extent: Codable, Equatable, Sendable {
        var halfWidth: Double
        var halfHeight: Double

        static func square(_ half: Double) -> Extent { Extent(halfWidth: half, halfHeight: half) }

        var isValid: Bool { halfWidth.isFinite && halfHeight.isFinite && halfWidth > 0 && halfHeight > 0 }
    }

    /// Who drew it — an agent's marks say so, and have their own ink.
    enum Author: String, Codable, Sendable { case user, agent }

    /// How it is drawn. Sizes are device points, not scaled by zoom.
    struct Style: Codable, Equatable, Sendable {
        /// `#rrggbb` — what a colour survives storage and MCP as.
        var colour: String
        var fontSize: Double
        var bold: Bool
        var stroke: Double

        static let userDefault = Style(colour: "#9ed9ff", fontSize: 11, bold: false, stroke: 1)
        static let agentDefault = Style(colour: "#8cffcc", fontSize: 11, bold: false, stroke: 1)

        static func author(_ author: Author) -> Style { author == .agent ? agentDefault : userDefault }

        /// `#rrggbb` or `rrggbb`, else nil — a typo must not become black.
        static func normalisedColour(_ text: String) -> String? {
            let hex = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
            return "#" + hex.lowercased()
        }

        /// What can be drawn and read: a zero stroke draws nothing, and the
        /// ceilings stop one mark covering the frame.
        func sane() -> Style {
            Style(colour: Self.normalisedColour(colour) ?? Self.userDefault.colour,
                  fontSize: fontSize.isFinite ? min(max(fontSize, 6), 72) : 11,
                  bold: bold,
                  stroke: stroke.isFinite ? min(max(stroke, 0.5), 20) : 1)
        }
    }

    var id: String
    var kind: Kind
    var anchor: Anchor
    var extent: Extent?
    var text: String = ""
    /// Where a callout's label sits, in screen points from the anchor — the
    /// label is furniture, not part of the image.
    var labelOffsetX: Double?
    var labelOffsetY: Double?
    var author: Author
    /// Nil: however a mark by this author is drawn.
    var style: Style?
    var createdAt: Date

    var effectiveStyle: Style { (style ?? .author(author)).sane() }

    static let defaultLabelOffset = (x: 36.0, y: -36.0)

    /// What is wrong with this mark, or nil when it can be drawn.
    var problem: String? {
        guard !id.isEmpty else { return "a mark needs an id" }
        guard anchor.isValid else { return "the \(anchor.space.rawValue) position is not a place that can be drawn" }
        if let extent {
            guard extent.isValid else { return "a shape needs a width and height greater than zero" }
        } else if kind.needsExtent {
            return "a \(kind.rawValue) needs a size — give it a radius or a halfWidth and halfHeight"
        }
        if let x = labelOffsetX, !x.isFinite { return "the label offset is not a finite distance" }
        if let y = labelOffsetY, !y.isFinite { return "the label offset is not a finite distance" }
        if kind == .callout || kind == .text, text.trimmingCharacters(in: .whitespaces).isEmpty {
            return "a \(kind.rawValue) mark needs text"
        }
        return nil
    }
}
