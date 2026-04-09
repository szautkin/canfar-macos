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

    var isValid: Bool { cd[0][0] != 0 || cd[1][1] != 0 }

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

    /// True when both CTYPE axes specify the TAN (gnomonic) projection.
    private var isTAN: Bool {
        ctype1.contains("TAN") && ctype2.contains("TAN")
    }

    /// Pixel (0-based) → World (RA, Dec) in degrees.
    ///
    /// For TAN-projected images this performs the full gnomonic deprojection.
    /// For other projections (or missing CTYPE) it falls back to linear interpolation.
    func pixelToWorld(x: Double, y: Double) -> (ra: Double, dec: Double) {
        let dx = x - crpix1
        let dy = y - crpix2
        let pixel = simd_double2(dx, dy)
        // Intermediate world coords in degrees via CD matrix.
        let inter = cd * pixel
        let xi  = inter.x
        let eta = inter.y

        guard isTAN else {
            // Linear fallback for non-TAN projections.
            return (ra: crval1 + xi, dec: crval2 + eta)
        }

        // TAN (gnomonic) deprojection.
        let xiRad  = xi  * (.pi / 180.0)
        let etaRad = eta * (.pi / 180.0)
        let ra0    = crval1 * (.pi / 180.0)
        let dec0   = crval2 * (.pi / 180.0)

        let denom = cos(dec0) - etaRad * sin(dec0)
        guard denom != 0 else {
            return (ra: crval1, dec: crval2)
        }
        let raRad  = ra0 + atan2(xiRad, denom)
        let decRad = atan2(
            (etaRad * cos(dec0) + sin(dec0)) * cos(raRad - ra0),
            denom
        )

        // Normalise RA to [0, 360).
        let decDeg = decRad * (180.0 / .pi)
        var raDeg = raRad * (180.0 / .pi)
        raDeg = raDeg.truncatingRemainder(dividingBy: 360.0)
        if raDeg < 0 { raDeg += 360.0 }
        return (ra: raDeg, dec: decDeg)
    }

    /// World (RA, Dec) in degrees → Pixel (0-based). Returns nil if singular.
    ///
    /// For TAN-projected images this performs the full gnomonic projection.
    /// For other projections (or missing CTYPE) it falls back to linear interpolation.
    func worldToPixel(ra: Double, dec: Double) -> (x: Double, y: Double)? {
        let det = simd_determinant(cd)
        guard abs(det) > 1e-30 else { return nil }

        guard isTAN else {
            // Linear fallback for non-TAN projections.
            let dworld = simd_double2(ra - crval1, dec - crval2)
            let pixel  = cdInv * dworld
            return (x: crpix1 + pixel.x, y: crpix2 + pixel.y)
        }

        // TAN (gnomonic) forward projection: sky → intermediate world coords.
        let raRad  = ra   * (.pi / 180.0)
        let decRad = dec  * (.pi / 180.0)
        let ra0    = crval1 * (.pi / 180.0)
        let dec0   = crval2 * (.pi / 180.0)

        let denom = sin(decRad) * sin(dec0) + cos(decRad) * cos(dec0) * cos(raRad - ra0)
        guard abs(denom) > 1e-30 else { return nil }

        let xi  = cos(decRad) * sin(raRad - ra0) / denom * (180.0 / .pi)
        let eta = (sin(decRad) * cos(dec0) - cos(decRad) * sin(dec0) * cos(raRad - ra0)) / denom * (180.0 / .pi)

        // Apply inverse CD matrix to get pixel offsets.
        let inter  = simd_double2(xi, eta)
        let dpixel = cdInv * inter
        return (x: crpix1 + dpixel.x, y: crpix2 + dpixel.y)
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

        guard cd[0][0] != 0 || cd[1][1] != 0 else {
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
            ctype2: header.string("CTYPE2") ?? ""
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
            ctype2: "DEC--TAN"
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
