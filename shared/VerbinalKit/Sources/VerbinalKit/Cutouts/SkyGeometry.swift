// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A direction on the sky, ICRS degrees.
public struct SkyPoint: Codable, Equatable, Hashable, Sendable {
    public var ra: Double
    public var dec: Double

    public init(ra: Double, dec: Double) {
        self.ra = ra
        self.dec = dec
    }
}

/// How a region lies against a footprint.
public enum SkyOverlap: Sendable, Equatable {
    case inside, partial, outside
}

/// Geometry on the sky for cutouts: distances, circles, and polygons
/// compared on the tangent plane at their centre — exact enough for the
/// sizes a cutout is, and free of the RA wrap at 0°/360°.
public enum SkyGeometry {
    private static let rad = Double.pi / 180

    public static func normaliseRA(_ ra: Double) -> Double {
        let r = ra.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Great-circle distance, degrees (haversine).
    public static func distance(_ a: SkyPoint, _ b: SkyPoint) -> Double {
        let dRA = (b.ra - a.ra) * rad, dDec = (b.dec - a.dec) * rad
        let h = sin(dDec / 2) * sin(dDec / 2) + cos(a.dec * rad) * cos(b.dec * rad) * sin(dRA / 2) * sin(dRA / 2)
        return 2 * asin(min(1, h.squareRoot())) / rad
    }

    /// The mean direction of `points`.
    public static func centroid(_ points: [SkyPoint]) -> SkyPoint {
        guard !points.isEmpty else { return SkyPoint(ra: 0, dec: 0) }
        var x = 0.0, y = 0.0, z = 0.0
        for p in points {
            let (px, py, pz) = unitVector(p)
            x += px; y += py; z += pz
        }
        return SkyPoint(ra: normaliseRA(atan2(y, x) / rad), dec: atan2(z, (x * x + y * y).squareRoot()) / rad)
    }

    /// Gnomonic projection about `centre`, degrees on the plane (x east, y
    /// north); nil for a point 90° or more away.
    public static func project(_ p: SkyPoint, about centre: SkyPoint) -> (x: Double, y: Double)? {
        let d0 = centre.dec * rad, d = p.dec * rad, da = (p.ra - centre.ra) * rad
        let cosC = sin(d0) * sin(d) + cos(d0) * cos(d) * cos(da)
        guard cosC > 1e-12 else { return nil }
        let xi = cos(d) * sin(da) / cosC
        let eta = (cos(d0) * sin(d) - sin(d0) * cos(d) * cos(da)) / cosC
        return (xi / rad, eta / rad)
    }

    /// The inverse of `project`.
    public static func unproject(x: Double, y: Double, about centre: SkyPoint) -> SkyPoint {
        let xi = x * rad, eta = y * rad
        let rho = (xi * xi + eta * eta).squareRoot()
        guard rho >= 1e-15 else { return centre }
        let c = atan(rho), d0 = centre.dec * rad
        let dec = asin(cos(c) * sin(d0) + eta * sin(c) * cos(d0) / rho)
        let ra = centre.ra * rad + atan2(xi * sin(c), rho * cos(d0) * cos(c) - eta * sin(d0) * sin(c))
        return SkyPoint(ra: normaliseRA(ra / rad), dec: dec / rad)
    }

    /// A circle's edge as `segments` points, counter-clockwise on the sky.
    public static func circleOutline(centre: SkyPoint, radius: Double, segments: Int = 64) -> [SkyPoint] {
        let d1 = centre.dec * rad, delta = radius * rad
        return (0..<segments).map { i in
            let theta = 2 * Double.pi * Double(i) / Double(segments)   // from north through east
            let d2 = asin(sin(d1) * cos(delta) + cos(d1) * sin(delta) * cos(theta))
            let a2 = centre.ra * rad + atan2(sin(theta) * sin(delta) * cos(d1), cos(delta) - sin(d1) * sin(d2))
            return SkyPoint(ra: normaliseRA(a2 / rad), dec: d2 / rad)
        }
    }

    /// Area in square degrees on the tangent plane; positive when the
    /// points run counter-clockwise as seen on the plane.
    public static func signedArea(_ polygon: [SkyPoint]) -> Double {
        guard polygon.count >= 3, let plane = plane(polygon, about: centroid(polygon)) else { return 0 }
        var sum = 0.0
        for i in plane.indices {
            let a = plane[i], b = plane[(i + 1) % plane.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    public static func area(_ polygon: [SkyPoint]) -> Double { abs(signedArea(polygon)) }

    /// Wound the way CADC winds its footprints, whichever way it was given.
    public static func skyWise(_ polygon: [SkyPoint]) -> [SkyPoint] {
        signedArea(polygon) > 0 ? polygon.reversed() : polygon
    }

    public static func contains(_ polygon: [SkyPoint], _ p: SkyPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        let centre = centroid(polygon)
        guard let flat = plane(polygon, about: centre), let q = project(p, about: centre) else { return false }
        return inside(flat, q)
    }

    /// Whether `region` is inside `footprint`, crosses its edge, or misses it.
    public static func overlap(_ region: [SkyPoint], _ footprint: [SkyPoint]) -> SkyOverlap {
        guard region.count >= 3, footprint.count >= 3 else { return .outside }
        let centre = centroid(footprint)
        guard let fp = plane(footprint, about: centre), let rg = plane(region, about: centre) else { return .outside }
        let within = rg.filter { inside(fp, $0) }.count
        if within == rg.count { return .inside }
        if within > 0 || fp.contains(where: { inside(rg, $0) }) || edgesCross(rg, fp) { return .partial }
        return .outside
    }

    // MARK: - On the plane

    private typealias Flat = (x: Double, y: Double)

    private static func unitVector(_ p: SkyPoint) -> (Double, Double, Double) {
        let ra = p.ra * rad, dec = p.dec * rad
        return (cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
    }

    private static func plane(_ points: [SkyPoint], about centre: SkyPoint) -> [Flat]? {
        var flat: [Flat] = []
        for p in points {
            guard let q = project(p, about: centre) else { return nil }
            flat.append(q)
        }
        return flat
    }

    private static func inside(_ polygon: [Flat], _ p: Flat) -> Bool {
        var isInside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                isInside.toggle()
            }
            j = i
        }
        return isInside
    }

    private static func edgesCross(_ a: [Flat], _ b: [Flat]) -> Bool {
        func turn(_ p: Flat, _ q: Flat, _ r: Flat) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        for i in a.indices {
            let a1 = a[i], a2 = a[(i + 1) % a.count]
            for j in b.indices {
                let b1 = b[j], b2 = b[(j + 1) % b.count]
                if (turn(b1, b2, a1) > 0) != (turn(b1, b2, a2) > 0), (turn(a1, a2, b1) > 0) != (turn(a1, a2, b2) > 0) {
                    return true
                }
            }
        }
        return false
    }
}
