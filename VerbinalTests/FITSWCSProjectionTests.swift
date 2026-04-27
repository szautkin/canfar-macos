// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Round-trip tests for the zenithal projection family added to
// `FITSWCSTransform`. Beyond TAN (already covered by the existing FITS
// suite) these pin SIN, STG, and ZEA — projections common in radio
// interferometry (SIN), wide-field optical (STG), and all-sky surveys
// (ZEA). Reference: Calabretta & Greisen 2002, A&A 395, 1077.

import XCTest
import simd
@testable import Verbinal

final class FITSWCSProjectionTests: XCTestCase {

    // MARK: - Projection code parsing

    func testProjectionCodeParsing() {
        // CTYPE strings come in two dash widths in practice.
        XCTAssertEqual(makeTransform(ctype1: "RA---TAN", ctype2: "DEC--TAN").projection, .tan)
        XCTAssertEqual(makeTransform(ctype1: "RA---SIN", ctype2: "DEC--SIN").projection, .sin)
        XCTAssertEqual(makeTransform(ctype1: "RA---STG", ctype2: "DEC--STG").projection, .stg)
        XCTAssertEqual(makeTransform(ctype1: "RA---ZEA", ctype2: "DEC--ZEA").projection, .zea)
        // Unknown code → linear fallback.
        XCTAssertEqual(makeTransform(ctype1: "RA---CAR", ctype2: "DEC--CAR").projection, .linear)
        // Mismatched axes → linear fallback (defensive).
        XCTAssertEqual(makeTransform(ctype1: "RA---TAN", ctype2: "DEC--SIN").projection, .linear)
        // Empty CTYPE → linear.
        XCTAssertEqual(makeTransform(ctype1: "", ctype2: "").projection, .linear)
    }

    // MARK: - Per-projection forward × inverse round-trips

    func testTANRoundTrip() {
        verifyRoundTrip(projection: .tan)
    }

    func testSINRoundTrip() {
        verifyRoundTrip(projection: .sin)
    }

    func testSTGRoundTrip() {
        verifyRoundTrip(projection: .stg)
    }

    func testZEARoundTrip() {
        verifyRoundTrip(projection: .zea)
    }

    /// Verify that for a small grid of (RA, Dec) points around a reference,
    /// `project(ra:dec:...) → deproject(...)` returns the original
    /// coordinates to within 1e-9 degrees (~3 µas — well below any pixel
    /// scale we'd surface in UI).
    private func verifyRoundTrip(projection: FITSWCSTransform.Projection,
                                 file: StaticString = #file, line: UInt = #line) {
        let crval1 = 180.0  // arbitrary RA — equator
        let crval2 = 30.0   // away from poles to keep the inverse stable

        // Test offsets up to ±0.5° (a typical wide-field image footprint).
        for dRa in stride(from: -0.5, through: 0.5, by: 0.25) {
            for dDec in stride(from: -0.5, through: 0.5, by: 0.25) {
                let ra = crval1 + dRa / cos(crval2 * .pi / 180)
                let dec = crval2 + dDec
                guard let plane = FITSWCSTransform.project(
                    ra: ra, dec: dec,
                    crval1: crval1, crval2: crval2,
                    projection: projection
                ) else {
                    XCTFail("Forward project returned nil for (\(ra), \(dec)) under \(projection)",
                            file: file, line: line)
                    continue
                }
                guard let world = FITSWCSTransform.deproject(
                    xi: plane.xi, eta: plane.eta,
                    crval1: crval1, crval2: crval2,
                    projection: projection
                ) else {
                    XCTFail("Inverse deproject returned nil for (\(plane.xi), \(plane.eta)) under \(projection)",
                            file: file, line: line)
                    continue
                }
                XCTAssertEqual(world.ra, ra, accuracy: 1e-9,
                               "RA round-trip failed under \(projection)",
                               file: file, line: line)
                XCTAssertEqual(world.dec, dec, accuracy: 1e-9,
                               "Dec round-trip failed under \(projection)",
                               file: file, line: line)
            }
        }
    }

    // MARK: - Domain edge cases

    func testSINRejectsOutOfHemisphere() {
        // SIN is undefined past ψ = 90° (ρ > 1 in radians, ≈ 57° in degrees).
        // 100° offset puts us solidly past the limit.
        let world = FITSWCSTransform.deproject(
            xi: 60, eta: 60,
            crval1: 0, crval2: 0,
            projection: .sin
        )
        XCTAssertNil(world)
    }

    func testZEARejectsOutOfDomain() {
        // ZEA radius cap is ρ = 2 rad ≈ 114.59°. Past that, out of domain.
        let world = FITSWCSTransform.deproject(
            xi: 200, eta: 200,
            crval1: 0, crval2: 0,
            projection: .zea
        )
        XCTAssertNil(world)
    }

    func testReferencePointMapsToOrigin() {
        // (RA0, Dec0) → (0, 0) in the projection plane for every zenithal projection.
        for proj in [FITSWCSTransform.Projection.tan, .sin, .stg, .zea] {
            let plane = FITSWCSTransform.project(
                ra: 180, dec: 30,
                crval1: 180, crval2: 30,
                projection: proj
            )
            XCTAssertEqual(plane?.xi ?? .nan, 0, accuracy: 1e-12, "\(proj)")
            XCTAssertEqual(plane?.eta ?? .nan, 0, accuracy: 1e-12, "\(proj)")
        }
    }

    func testOriginMapsToReferencePoint() {
        // (0, 0) in the plane → (RA0, Dec0) for every projection.
        for proj in [FITSWCSTransform.Projection.tan, .sin, .stg, .zea] {
            let world = FITSWCSTransform.deproject(
                xi: 0, eta: 0,
                crval1: 180, crval2: 30,
                projection: proj
            )
            XCTAssertEqual(world?.ra ?? .nan, 180, accuracy: 1e-12, "\(proj)")
            XCTAssertEqual(world?.dec ?? .nan, 30, accuracy: 1e-12, "\(proj)")
        }
    }

    // MARK: - Helpers

    private func makeTransform(ctype1: String, ctype2: String) -> FITSWCSTransform {
        // Use the simplest CD matrix (1° per pixel, axis-aligned) — the
        // projection logic depends only on CTYPE for these tests.
        let cd = simd_double2x2(columns: (
            SIMD2<Double>(1, 0),
            SIMD2<Double>(0, 1)
        ))
        return FITSWCSTransform(
            crpix1: 0, crpix2: 0,
            crval1: 0, crval2: 0,
            cd: cd,
            cdInv: simd_inverse(cd),
            ctype1: ctype1, ctype2: ctype2
        )
    }
}
