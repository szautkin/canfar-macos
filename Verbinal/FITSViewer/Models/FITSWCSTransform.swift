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

    /// Pixel (0-based) → World (RA, Dec) in degrees.
    func pixelToWorld(x: Double, y: Double) -> (ra: Double, dec: Double) {
        let dx = x - crpix1
        let dy = y - crpix2
        let pixel = simd_double2(dx, dy)
        let world = cd * pixel
        return (ra: crval1 + world.x, dec: crval2 + world.y)
    }

    /// World (RA, Dec) in degrees → Pixel (0-based). Returns nil if singular.
    func worldToPixel(ra: Double, dec: Double) -> (x: Double, y: Double)? {
        let det = simd_determinant(cd)
        guard abs(det) > 1e-30 else { return nil }
        let dworld = simd_double2(ra - crval1, dec - crval2)
        let pixel = cdInv * dworld
        return (x: crpix1 + pixel.x, y: crpix2 + pixel.y)
    }

    /// Extract WCS from a parsed FITS header.
    static func fromHeader(_ header: FITSHeader) -> FITSWCSTransform? {
        let crpix1 = header.double("CRPIX1")
        let crpix2 = header.double("CRPIX2")
        let crval1 = header.double("CRVAL1")
        let crval2 = header.double("CRVAL2")

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

        guard cd[0][0] != 0 || cd[1][1] != 0 else { return nil }

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

    // MARK: - Formatting

    /// Format RA in degrees to sexagesimal (HHhMMmSS.SSs).
    static func formatRA(_ raDeg: Double) -> String {
        var ra = raDeg / 15.0
        if ra < 0 { ra += 24 }
        let h = Int(ra)
        let m = Int((ra - Double(h)) * 60)
        let s = (ra - Double(h) - Double(m) / 60.0) * 3600
        return String(format: "%02dh%02dm%05.2fs", h, m, s)
    }

    /// Format Dec in degrees to sexagesimal (+DD°MM'SS.S").
    static func formatDec(_ decDeg: Double) -> String {
        let sign = decDeg >= 0 ? "+" : "-"
        let dec = abs(decDeg)
        let d = Int(dec)
        let m = Int((dec - Double(d)) * 60)
        let s = (dec - Double(d) - Double(m) / 60.0) * 3600
        return String(format: "%@%02d\u{00b0}%02d'%04.1f\"", sign, d, m, s)
    }
}
