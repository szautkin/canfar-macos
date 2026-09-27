// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A region on the sky — the one form a cutout region takes everywhere:
/// the editor's fields, an agent's request, the saved Research record, and
/// what goes to SODA. A box is its own shape (its width and height come
/// back when an editor reopens it); SODA has no box, so it goes as the
/// polygon of its corners.
public struct SkyRegion: Codable, Equatable, Hashable, Sendable {

    public enum Shape: String, Codable, Sendable {
        /// Everything within a radius of a point — SODA's CIRCLE.
        case circle
        /// A rectangle about a point, width along RA and height along Dec.
        case box
        /// Any polygon — SODA's POLYGON.
        case polygon
    }

    /// What is wrong with a region.
    public enum Problem: Equatable, Sendable {
        case notANumber, decOutOfRange, sizeNotPositive, tooLarge, tooFewVertices, degenerate
    }

    /// Nothing larger is a cutout: SODA's circle stops at 180°, and no image is near 90°.
    public static let maxSize: Double = 90

    public var shape: Shape
    /// Centre, for a circle or a box.
    public var ra: Double = 0
    public var dec: Double = 0
    /// Degrees, for a circle.
    public var radius: Double = 0
    /// Degrees on the sky along RA and along Dec, for a box.
    public var width: Double = 0
    public var height: Double = 0
    /// In order, for a polygon.
    public var vertices: [SkyPoint] = []

    public static func circle(ra: Double, dec: Double, radius: Double) -> SkyRegion {
        SkyRegion(shape: .circle, ra: SkyGeometry.normaliseRA(ra), dec: dec, radius: radius)
    }

    public static func box(ra: Double, dec: Double, width: Double, height: Double) -> SkyRegion {
        SkyRegion(shape: .box, ra: SkyGeometry.normaliseRA(ra), dec: dec, width: width, height: height)
    }

    /// Wound the way CADC winds its own footprints, whichever way it was drawn.
    public static func polygon(_ vertices: [SkyPoint]) -> SkyRegion {
        SkyRegion(shape: .polygon,
                  vertices: SkyGeometry.skyWise(vertices.map { SkyPoint(ra: SkyGeometry.normaliseRA($0.ra), dec: $0.dec) }))
    }

    /// Given for a circle or box; a polygon's mean direction.
    public var centre: SkyPoint {
        shape == .polygon ? SkyGeometry.centroid(vertices) : SkyPoint(ra: ra, dec: dec)
    }

    /// The region as a polygon: a box's corners, a polygon's vertices, a
    /// circle's edge — what overlap and drawing work from.
    public func outline(circleSegments: Int = 64) -> [SkyPoint] {
        switch shape {
        case .circle: return SkyGeometry.circleOutline(centre: centre, radius: radius, segments: circleSegments)
        case .box: return boxCorners()
        case .polygon: return vertices
        }
    }

    /// How far the region reaches from its centre, degrees.
    public var reach: Double {
        guard shape != .circle else { return radius }
        let c = centre
        return outline().map { SkyGeometry.distance(c, $0) }.max() ?? 0
    }

    /// The SODA parameter it is sent as.
    public var sodaParameter: String { shape == .circle ? "CIRCLE" : "POLYGON" }

    /// The parameter's value: "ra dec radius", or "ra1 dec1 ra2 dec2 …", degrees.
    public var sodaValue: String {
        shape == .circle
            ? Self.join([ra, dec, radius])
            : Self.join(outline().flatMap { [$0.ra, $0.dec] })
    }

    /// Nil when the region can be sent.
    public var problem: Problem? {
        if shape == .polygon {
            guard vertices.count >= 3 else { return .tooFewVertices }
            guard vertices.allSatisfy({ $0.ra.isFinite && $0.dec.isFinite }) else { return .notANumber }
            guard vertices.allSatisfy({ (-90...90).contains($0.dec) }) else { return .decOutOfRange }
            guard SkyGeometry.area(vertices) > 1e-12 else { return .degenerate }
            return reach > Self.maxSize ? .tooLarge : nil
        }
        let sizes = shape == .circle ? [radius] : [width, height]
        guard ra.isFinite, dec.isFinite, sizes.allSatisfy(\.isFinite) else { return .notANumber }
        guard (-90...90).contains(dec) else { return .decOutOfRange }
        guard sizes.allSatisfy({ $0 > 0 }) else { return .sizeNotPositive }
        return sizes.contains { $0 > Self.maxSize } ? .tooLarge : nil
    }

    /// A short account — "r 2.0′ @ 10.68000°, +41.27000°", "5′ × 3′ @ …".
    /// Symbols, so it reads the same in either language.
    public var summary: String {
        let c = centre
        let at = String(format: "@ %.5f°, %+.5f°", c.ra, c.dec)
        switch shape {
        case .circle: return "r \(Self.angle(radius)) \(at)"
        case .box: return "\(Self.angle(width)) × \(Self.angle(height)) \(at)"
        case .polygon: return "⬠ \(vertices.count) \(at)"
        }
    }

    /// An angle at the unit that reads best: arcseconds, arcminutes or degrees.
    public static func angle(_ degrees: Double) -> String {
        func trimmed(_ v: Double, _ digits: Int) -> String {
            var s = String(format: "%.\(digits)f", v)
            while s.contains("."), s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        if degrees < 1.0 / 60 { return "\(trimmed(degrees * 3600, 1))″" }
        if degrees < 1 { return "\(trimmed(degrees * 60, 2))′" }
        return "\(trimmed(degrees, 3))°"
    }

    /// South-east, south-west, north-west, north-east — CADC's order — on
    /// the tangent plane, so the box is a true rectangle at any Dec.
    private func boxCorners() -> [SkyPoint] {
        let c = SkyPoint(ra: ra, dec: dec), hw = width / 2, hh = height / 2
        return [(hw, -hh), (-hw, -hh), (-hw, hh), (hw, hh)].map { SkyGeometry.unproject(x: $0.0, y: $0.1, about: c) }
    }

    private static func join(_ values: [Double]) -> String {
        values.map { v in
            var s = String(format: "%.10f", v)
            while s.contains("."), s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }.joined(separator: " ")
    }
}
