// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import simd

/// World Coordinate System transform: pixel ↔ world (RA/Dec).
struct FITSWCSTransform: Sendable {
    let crpix1: Double
    let crpix2: Double
    let crval1: Double
    let crval2: Double
    let cd: simd_double2x2
    let cdInv: simd_double2x2
    let ctype1: String
    let ctype2: String
    /// True when the WCS was constructed from legacy header keywords (RA/DEC strings)
    /// rather than standard WCS keywords. Coordinates are approximate — no CD matrix,
    /// pixel scale is guessed, no rotation. The user should be warned that spatial
    /// operations (crosshair, Go To, Search Here) may be imprecise.
    var isApproximate: Bool = false

    /// Valid only when BOTH diagonal CD elements are non-zero — a half-zero
    /// matrix (e.g. CDELT1=0, CDELT2≠0) is degenerate and produces unreliable
    /// pixel↔world transforms.
    var isValid: Bool { cd[0][0] != 0 && cd[1][1] != 0 }

    /// North angle in degrees (rotation from celestial North).
    /// North angle in degrees. CD matrix is column-major:
    /// cd[0] = (CD1_1, CD2_1), cd[1] = (CD1_2, CD2_2)
    /// Formula: atan2(-CD1_2, CD2_2) = atan2(-cd[1][0], cd[1][1])
    var northAngle: Double {
        atan2(-cd[1][0], cd[1][1]) * 180.0 / .pi
    }

    /// True if image has parity flip (det(CD) > 0).
    var hasParityFlip: Bool {
        simd_determinant(cd) > 0
    }

    /// Pixel scale in arcseconds per pixel (geometric mean).
    var pixelScaleArcsec: Double {
        let sx = sqrt(cd[0][0] * cd[0][0] + cd[1][0] * cd[1][0])
        let sy = sqrt(cd[0][1] * cd[0][1] + cd[1][1] * cd[1][1])
        return sqrt(sx * sy) * 3600.0
    }

    /// Projection algorithm parsed from `CTYPE1`/`CTYPE2`. Beyond these four
    /// zenithal projections we fall back to a linear interpolation that
    /// is *only* approximately correct near the reference pixel — the
    /// `isApproximate` flag warns the UI not to trust off-centre pixels.
    enum Projection: Sendable, Equatable {
        case tan        // gnomonic — most common for narrow-field optical/IR
        case sin        // slant orthographic — radio interferometry
        case stg        // stereographic — preserves angles, used for wide fields
        case zea        // zenithal equal-area — preserves areas
        case linear     // unknown / unrecognised — degrees-per-pixel fallback
    }

    /// Resolved projection. Both axes must agree on the projection code,
    /// otherwise we fall back to linear.
    var projection: Projection {
        let p1 = Self.projectionCode(from: ctype1)
        let p2 = Self.projectionCode(from: ctype2)
        guard p1 == p2 else { return .linear }
        switch p1 {
        case "TAN": return .tan
        case "SIN": return .sin
        case "STG": return .stg
        case "ZEA": return .zea
        default:    return .linear
        }
    }

    /// Extract the trailing 3-character projection code from a CTYPE
    /// string (e.g. `"RA---TAN"` → `"TAN"`, `"DEC--SIN"` → `"SIN"`).
    private static func projectionCode(from ctype: String) -> String {
        // CTYPE format: "{coord}---{proj}" or "{coord}--{proj}" — split on
        // dashes and take the last non-empty segment.
        let parts = ctype.split(separator: "-", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? ""
    }

    /// Pixel (0-based) → World (RA, Dec) in degrees.
    ///
    /// Dispatches on `projection`: zenithal codes (TAN/SIN/STG/ZEA) get a
    /// rigorous spherical deprojection; anything else (or missing CTYPE)
    /// falls back to linear interpolation around the reference pixel.
    func pixelToWorld(x: Double, y: Double) -> (ra: Double, dec: Double) {
        let dx = x - crpix1
        let dy = y - crpix2
        let pixel = simd_double2(dx, dy)
        // Intermediate world coords in degrees via CD matrix.
        let inter = cd * pixel
        let xi  = inter.x
        let eta = inter.y

        if let world = Self.deproject(xi: xi, eta: eta,
                                      crval1: crval1, crval2: crval2,
                                      projection: projection) {
            return world
        }
        // Either an unknown projection or an out-of-domain plane point —
        // surface the linear interpolation rather than nil so the UI can
        // still display something near the reference pixel.
        return (ra: crval1 + xi, dec: crval2 + eta)
    }

    /// World (RA, Dec) in degrees → Pixel (0-based). Returns nil if singular.
    func worldToPixel(ra: Double, dec: Double) -> (x: Double, y: Double)? {
        let det = simd_determinant(cd)
        guard abs(det) > 1e-30 else { return nil }

        let inter: simd_double2
        if let plane = Self.project(ra: ra, dec: dec,
                                    crval1: crval1, crval2: crval2,
                                    projection: projection) {
            inter = simd_double2(plane.xi, plane.eta)
        } else if projection == .linear {
            inter = simd_double2(ra - crval1, dec - crval2)
        } else {
            return nil
        }

        let dpixel = cdInv * inter
        return (x: crpix1 + dpixel.x, y: crpix2 + dpixel.y)
    }

    // MARK: - Spherical projection math (zenithal family)
    //
    // For all zenithal projections the math factors as:
    //   1. Compute angular distance ψ between target and reference, plus
    //      position angle B (north-from-reference, east-positive).
    //   2. Map ψ → ρ via a projection-specific radial law:
    //        TAN: ρ = tan(ψ)
    //        SIN: ρ = sin(ψ)
    //        STG: ρ = 2·tan(ψ/2)
    //        ZEA: ρ = 2·sin(ψ/2)
    //   3. ξ = ρ · sin(B), η = ρ · cos(B).
    // Inverse just runs the chain backwards. References:
    //   • Calabretta & Greisen, A&A 395, 1077 (2002), "Representations of
    //     celestial coordinates in FITS", Paper II.

    /// Forward project (RA, Dec) → intermediate world (ξ, η) in degrees.
    /// Returns nil for projection-domain violations (e.g. SIN beyond the
    /// hemisphere) or a degenerate `linear` request that the caller should
    /// handle separately.
    static func project(
        ra: Double,
        dec: Double,
        crval1: Double,
        crval2: Double,
        projection: Projection
    ) -> (xi: Double, eta: Double)? {
        guard projection != .linear else { return nil }

        let raRad = ra * .pi / 180.0
        let decRad = dec * .pi / 180.0
        let ra0 = crval1 * .pi / 180.0
        let dec0 = crval2 * .pi / 180.0

        let cosPsi = sin(decRad) * sin(dec0) + cos(decRad) * cos(dec0) * cos(raRad - ra0)
        let xNum = cos(decRad) * sin(raRad - ra0)
        let yNum = sin(decRad) * cos(dec0) - cos(decRad) * sin(dec0) * cos(raRad - ra0)

        let xi: Double
        let eta: Double
        switch projection {
        case .tan:
            // Forward hemisphere only.
            guard cosPsi > 1e-12 else { return nil }
            xi = xNum / cosPsi * (180.0 / .pi)
            eta = yNum / cosPsi * (180.0 / .pi)
        case .sin:
            // SIN is well-defined throughout the forward hemisphere.
            xi = xNum * (180.0 / .pi)
            eta = yNum * (180.0 / .pi)
        case .stg:
            // Defined everywhere except the antipode.
            let denom = 1 + cosPsi
            guard denom > 1e-12 else { return nil }
            xi = 2 * xNum / denom * (180.0 / .pi)
            eta = 2 * yNum / denom * (180.0 / .pi)
        case .zea:
            // Defined everywhere except the antipode; equal-area.
            guard cosPsi > -1 + 1e-12 else { return nil }
            let factor = sqrt(2 / (1 + cosPsi))
            xi = xNum * factor * (180.0 / .pi)
            eta = yNum * factor * (180.0 / .pi)
        case .linear:
            return nil
        }
        return (xi: xi, eta: eta)
    }

    /// Inverse project intermediate world (ξ, η) in degrees → (RA, Dec).
    /// Returns nil only when the input is outside the projection's domain
    /// (SIN/ZEA past their respective radii). RA is normalised to [0, 360).
    static func deproject(
        xi: Double,
        eta: Double,
        crval1: Double,
        crval2: Double,
        projection: Projection
    ) -> (ra: Double, dec: Double)? {
        guard projection != .linear else { return nil }

        let xiRad = xi * .pi / 180.0
        let etaRad = eta * .pi / 180.0
        let rho = sqrt(xiRad * xiRad + etaRad * etaRad)
        let ra0 = crval1 * .pi / 180.0
        let dec0 = crval2 * .pi / 180.0

        // At the reference pixel, all projections collapse to the centre.
        if rho < 1e-12 {
            return (ra: crval1, dec: crval2)
        }

        let cosPsi: Double
        let sinPsi: Double
        switch projection {
        case .tan:
            // ψ = atan(ρ).  cos(ψ) = 1/√(1+ρ²), sin(ψ) = ρ/√(1+ρ²)
            let denom = sqrt(1 + rho * rho)
            cosPsi = 1 / denom
            sinPsi = rho / denom
        case .sin:
            // ψ = asin(ρ).  Domain: ρ ≤ 1 (i.e., visible hemisphere).
            guard rho <= 1.0 else { return nil }
            sinPsi = rho
            cosPsi = sqrt(max(0, 1 - rho * rho))
        case .stg:
            // ψ = 2·atan(ρ/2)
            let halfPsi = atan(rho / 2)
            cosPsi = cos(2 * halfPsi)
            sinPsi = sin(2 * halfPsi)
        case .zea:
            // ψ = 2·asin(ρ/2).  Domain: ρ ≤ 2.
            guard rho <= 2.0 else { return nil }
            let halfPsi = asin(rho / 2)
            cosPsi = cos(2 * halfPsi)
            sinPsi = sin(2 * halfPsi)
        case .linear:
            return nil
        }

        // Position angle B: sin(B) = ξ/ρ, cos(B) = η/ρ. Convention: B
        // measured from celestial north, east-positive.
        let sinB = xiRad / rho
        let cosB = etaRad / rho

        // Inverse spherical formulas for any zenithal projection:
        //   sin(δ) = cos(ψ)·sin(δ₀) + sin(ψ)·cos(B)·cos(δ₀)
        //   tan(α-α₀) = sin(ψ)·sin(B) / (cos(ψ)·cos(δ₀) - sin(ψ)·cos(B)·sin(δ₀))
        let sinDec = cosPsi * sin(dec0) + sinPsi * cosB * cos(dec0)
        let decRad = asin(min(1, max(-1, sinDec)))

        let yArg = sinPsi * sinB
        let xArg = cosPsi * cos(dec0) - sinPsi * cosB * sin(dec0)
        let raRad = ra0 + atan2(yArg, xArg)

        var raDeg = raRad * (180.0 / .pi)
        raDeg = raDeg.truncatingRemainder(dividingBy: 360.0)
        if raDeg < 0 { raDeg += 360.0 }
        return (ra: raDeg, dec: decRad * (180.0 / .pi))
    }

    /// Extract WCS from a parsed FITS header.
    static func fromHeader(_ header: FITSHeader) -> FITSWCSTransform? {
        let crpix1 = header.double("CRPIX1")
        let crpix2 = header.double("CRPIX2")
        let crval1 = header.double("CRVAL1")
        let crval2 = header.double("CRVAL2")

        guard crpix1.isFinite, crpix2.isFinite, crval1.isFinite, crval2.isFinite else {
            return nil
        }

        let cd: simd_double2x2
        if header.contains("CD1_1") {
            cd = simd_double2x2(columns: (
                simd_double2(header.double("CD1_1"), header.double("CD2_1")),
                simd_double2(header.double("CD1_2"), header.double("CD2_2"))
            ))
        } else {
            let cdelt1 = header.double("CDELT1")
            let cdelt2 = header.double("CDELT2")
            let crota2 = header.double("CROTA2") * .pi / 180.0
            cd = simd_double2x2(columns: (
                simd_double2(cdelt1 * cos(crota2), cdelt1 * sin(crota2)),
                simd_double2(-cdelt2 * sin(crota2), cdelt2 * cos(crota2))
            ))
        }

        // Reject degenerate/half-zero CD matrices (e.g. CDELT1=0 with CDELT2≠0).
        // AND instead of OR — a half-zero matrix is non-invertible for WCS purposes.
        guard cd[0][0] != 0 && cd[1][1] != 0 else {
            // No CD matrix or CDELT — try to construct approximate WCS
            // from non-standard RA/DEC header keywords (common in old observatory files)
            return fromLegacyHeader(header)
        }

        return FITSWCSTransform(
            crpix1: crpix1 - 1, // FITS 1-based → 0-based
            crpix2: crpix2 - 1,
            crval1: crval1,
            crval2: crval2,
            cd: cd,
            cdInv: simd_inverse(cd),
            ctype1: header.string("CTYPE1") ?? "",
            ctype2: header.string("CTYPE2") ?? "",
            isApproximate: false
        )
    }

    /// Construct approximate WCS from legacy RA/DEC keywords (sexagesimal strings).
    /// Used when standard WCS keywords (CRVAL, CD, CDELT) are absent.
    /// Assumes RA/DEC points to image center with a default plate scale.
    private static func fromLegacyHeader(_ header: FITSHeader) -> FITSWCSTransform? {
        // Try RA/DEC keywords (sexagesimal: HH:MM:SS.SS / ±DD:MM:SS.S)
        guard let raStr = header.string("RA"),
              let decStr = header.string("DEC"),
              let ra = parseRA(raStr),
              let dec = parseDec(decStr) else { return nil }

        let naxis1 = header.int("NAXIS1")
        let naxis2 = header.int("NAXIS2")
        guard naxis1 > 0, naxis2 > 0 else { return nil }

        // Use SECPIX or PIXSCALE if available, otherwise estimate ~0.5"/px
        var pixelScale = header.double("SECPIX")
        if pixelScale == 0 { pixelScale = header.double("PIXSCALE") }
        if pixelScale == 0 { pixelScale = header.double("SCALE") }
        if pixelScale == 0 { pixelScale = 0.5 } // conservative default

        let cdelt = pixelScale / 3600.0 // arcsec → degrees
        let cd = simd_double2x2(columns: (
            simd_double2(-cdelt, 0),   // RA increases to the left (standard)
            simd_double2(0, cdelt)
        ))

        return FITSWCSTransform(
            crpix1: Double(naxis1) / 2.0,  // image center
            crpix2: Double(naxis2) / 2.0,
            crval1: ra,
            crval2: dec,
            cd: cd,
            cdInv: simd_inverse(cd),
            ctype1: "RA---TAN",
            ctype2: "DEC--TAN",
            isApproximate: true
        )
    }

    /// Parse sexagesimal RA (HH:MM:SS.SS or HH MM SS.SS) to degrees.
    ///
    /// Validates: h in [0, 24), m in [0, 60), s in [0, 60).
    static func parseRA(_ str: String) -> Double? {
        let parts = str.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: ": "))
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        guard let h = Double(parts[0]) else { return nil }
        let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
        let s = parts.count > 2 ? (Double(parts[2]) ?? 0) : 0
        guard h >= 0, h < 24, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return (h + m / 60.0 + s / 3600.0) * 15.0 // hours → degrees
    }

    /// Parse sexagesimal Dec (±DD:MM:SS.S or ±DD MM SS.S) to degrees.
    ///
    /// Validates: d in [0, 90], m in [0, 60), s in [0, 60).
    static func parseDec(_ str: String) -> Double? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let sign: Double = trimmed.hasPrefix("-") ? -1 : 1
        let cleaned = trimmed.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ": "))
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        guard let d = Double(parts[0]) else { return nil }
        let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
        let s = parts.count > 2 ? (Double(parts[2]) ?? 0) : 0
        guard d >= 0, d <= 90, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return sign * (d + m / 60.0 + s / 3600.0)
    }

    // MARK: - Formatting

    /// Format RA in degrees to sexagesimal (HHhMMmSS.SSs).
    static func formatRA(_ raDeg: Double) -> String {
        guard raDeg.isFinite else { return "--h--m--.--s" }
        var ra = raDeg / 15.0
        if ra < 0 { ra += 24 }
        let h = Int(ra)
        let m = Int((ra - Double(h)) * 60)
        let s = (ra - Double(h) - Double(m) / 60.0) * 3600
        return String(format: "%02dh%02dm%05.2fs", h, m, s)
    }

    /// Format Dec in degrees to sexagesimal (+DD°MM'SS.S").
    static func formatDec(_ decDeg: Double) -> String {
        guard decDeg.isFinite else { return "--\u{00b0}--'--.--\"" }
        let sign = decDeg >= 0 ? "+" : "-"
        let dec = abs(decDeg)
        let d = Int(dec)
        let m = Int((dec - Double(d)) * 60)
        let s = (dec - Double(d) - Double(m) / 60.0) * 3600
        return String(format: "%@%02d\u{00b0}%02d'%04.1f\"", sign, d, m, s)
    }
}
