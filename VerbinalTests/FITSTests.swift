// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import simd
@testable import Verbinal

final class FITSWCSTransformTests: XCTestCase {

    private func makeWCS() -> FITSWCSTransform {
        // Simple WCS: 1 arcsec/pixel, no rotation
        let cd = simd_double2x2(columns: (
            simd_double2(1.0 / 3600.0, 0),  // CDELT1 = 1 arcsec in degrees
            simd_double2(0, 1.0 / 3600.0)   // CDELT2 = 1 arcsec in degrees
        ))
        return FITSWCSTransform(
            crpix1: 512, crpix2: 512,
            crval1: 180.0, crval2: 45.0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "RA---TAN", ctype2: "DEC--TAN"
        )
    }

    func testPixelToWorldAtReferencePixel() {
        let wcs = makeWCS()
        let (ra, dec) = wcs.pixelToWorld(x: 512, y: 512)
        XCTAssertEqual(ra, 180.0, accuracy: 1e-10)
        XCTAssertEqual(dec, 45.0, accuracy: 1e-10)
    }

    func testPixelToWorldOffset() {
        let wcs = makeWCS()
        // 3600 pixels = 1° of xi in intermediate world coords at 1 arcsec/pixel.
        // With TAN projection at dec0=45°, the gnomonic deprojection means:
        //   - RA shifts more than 1° (cos(dec) foreshortening on the sphere).
        //   - Dec changes slightly too, because a pure xi offset at dec0≠0 traces
        //     a small circle, not a declination parallel.
        // Verify the result via a pixel round-trip rather than hardcoded linear values.
        let x: Double = 512 + 3600
        let y: Double = 512
        let (ra, _) = wcs.pixelToWorld(x: x, y: y)
        // RA must be east of 180° (xi > 0).
        XCTAssertGreaterThan(ra, 180.0)
        // Round-trip: world → pixel must recover the original pixel coordinates.
        let result = wcs.worldToPixel(ra: ra, dec: wcs.pixelToWorld(x: x, y: y).dec)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, x, accuracy: 1e-8)
        XCTAssertEqual(result!.y, y, accuracy: 1e-8)
    }

    func testWorldToPixelRoundTrip() {
        let wcs = makeWCS()
        let (ra, dec) = wcs.pixelToWorld(x: 100, y: 200)
        let result = wcs.worldToPixel(ra: ra, dec: dec)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 100, accuracy: 1e-8)
        XCTAssertEqual(result!.y, 200, accuracy: 1e-8)
    }

    func testNorthAngleNoRotation() {
        let wcs = makeWCS()
        XCTAssertEqual(wcs.northAngle, 0, accuracy: 1e-10)
    }

    func testPixelScaleArcsec() {
        let wcs = makeWCS()
        XCTAssertEqual(wcs.pixelScaleArcsec, 1.0, accuracy: 1e-10)
    }

    func testParityFlip() {
        let wcs = makeWCS()
        // Positive CDELT1 × positive CDELT2 with no rotation → det > 0 → flip
        XCTAssertTrue(wcs.hasParityFlip)
    }

    func testFormatRA() {
        // 180 degrees = 12 hours
        let formatted = FITSWCSTransform.formatRA(180.0)
        XCTAssertTrue(formatted.hasPrefix("12h00m"), "Expected 12h00m, got: \(formatted)")
    }

    func testFormatDec() {
        let formatted = FITSWCSTransform.formatDec(45.0)
        XCTAssertTrue(formatted.hasPrefix("+45"), "Expected +45, got: \(formatted)")
    }

    func testFormatDecNegative() {
        let formatted = FITSWCSTransform.formatDec(-30.5)
        XCTAssertTrue(formatted.hasPrefix("-30"), "Expected -30, got: \(formatted)")
    }

    // MARK: - TAN projection tests

    /// Round-trip at a large offset (10° away from reference pixel) must recover
    /// the original pixel to sub-pixel accuracy.
    func testRoundTripLargeOffset() {
        // 1 arcsec/pixel, centre at (180°, 45°). 10° = 36 000 pixels.
        let cd = simd_double2x2(columns: (
            simd_double2(1.0 / 3600.0, 0),
            simd_double2(0, 1.0 / 3600.0)
        ))
        let wcs = FITSWCSTransform(
            crpix1: 18000, crpix2: 18000,
            crval1: 180.0, crval2: 45.0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "RA---TAN", ctype2: "DEC--TAN"
        )

        // Test several large-offset pixels.
        let testPixels: [(Double, Double)] = [
            (18000 + 36000, 18000),       // +10° xi
            (18000 - 36000, 18000),       // -10° xi
            (18000, 18000 + 36000),       // +10° eta
            (18000 + 25456, 18000 + 18000) // diagonal
        ]
        for (px, py) in testPixels {
            let (ra, dec) = wcs.pixelToWorld(x: px, y: py)
            let result = wcs.worldToPixel(ra: ra, dec: dec)
            XCTAssertNotNil(result, "worldToPixel returned nil for pixel (\(px), \(py))")
            XCTAssertEqual(result!.x, px, accuracy: 1e-6,
                "Round-trip x failed for pixel (\(px), \(py)): ra=\(ra) dec=\(dec)")
            XCTAssertEqual(result!.y, py, accuracy: 1e-6,
                "Round-trip y failed for pixel (\(px), \(py)): ra=\(ra) dec=\(dec)")
        }
    }

    /// Coordinates near the RA=0°/360° wrap boundary must survive the full
    /// pixel→world→pixel round-trip without drifting across the boundary.
    func testRAWrappingNearZero() {
        // Centre near RA=1° so that a small negative xi lands below RA=0°.
        let cd = simd_double2x2(columns: (
            simd_double2(1.0 / 3600.0, 0),
            simd_double2(0, 1.0 / 3600.0)
        ))
        let wcs = FITSWCSTransform(
            crpix1: 512, crpix2: 512,
            crval1: 1.0, crval2: 0.0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "RA---TAN", ctype2: "DEC--TAN"
        )

        // Reference pixel → must be exactly at CRVAL.
        let (raRef, decRef) = wcs.pixelToWorld(x: 512, y: 512)
        XCTAssertEqual(raRef, 1.0, accuracy: 1e-10)
        XCTAssertEqual(decRef, 0.0, accuracy: 1e-10)

        // A pixel 7200 steps left of centre → xi ≈ -2°, so raw RA ≈ -1° → wraps to 359°.
        let (raNeg, _) = wcs.pixelToWorld(x: 512 - 7200, y: 512)
        XCTAssertGreaterThanOrEqual(raNeg, 0.0, "RA must not be negative after wrap")
        XCTAssertLessThan(raNeg, 360.0, "RA must be < 360 after wrap")

        // Round-trip must recover the original pixel.
        let result = wcs.worldToPixel(ra: raNeg, dec: 0.0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 512 - 7200, accuracy: 1e-6)
        XCTAssertEqual(result!.y, 512, accuracy: 1e-6)
    }

    /// Non-TAN CTYPE must fall back to the linear approximation; at small offsets
    /// the linear and TAN values are nearly identical, but the test confirms the
    /// correct code path is taken (no atan2 distortion).
    func testNonTANCTypeLinearFallback() {
        let cd = simd_double2x2(columns: (
            simd_double2(1.0 / 3600.0, 0),
            simd_double2(0, 1.0 / 3600.0)
        ))
        // Use CAR (plate-carrée) projection — must use linear path.
        let wcs = FITSWCSTransform(
            crpix1: 512, crpix2: 512,
            crval1: 180.0, crval2: 0.0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "RA---CAR", ctype2: "DEC--CAR"
        )

        // At the reference pixel the result is always exact.
        let (ra0, dec0) = wcs.pixelToWorld(x: 512, y: 512)
        XCTAssertEqual(ra0, 180.0, accuracy: 1e-10)
        XCTAssertEqual(dec0, 0.0, accuracy: 1e-10)

        // 3600 px offset = 1° in linear coords; the linear path must return exactly 181°.
        // (TAN at dec0=0° happens to coincide with linear for eta=0, but at dec0=45° it would not.)
        let (ra1, dec1) = wcs.pixelToWorld(x: 512 + 3600, y: 512)
        XCTAssertEqual(ra1, 181.0, accuracy: 1e-10, "Non-TAN CTYPE must use linear formula")
        XCTAssertEqual(dec1, 0.0, accuracy: 1e-10)

        // Empty CTYPE also falls back to linear.
        let wcsEmpty = FITSWCSTransform(
            crpix1: 512, crpix2: 512,
            crval1: 180.0, crval2: 45.0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "", ctype2: ""
        )
        let (raE, decE) = wcsEmpty.pixelToWorld(x: 512 + 3600, y: 512)
        XCTAssertEqual(raE, 181.0, accuracy: 1e-10, "Empty CTYPE must use linear formula")
        XCTAssertEqual(decE, 45.0, accuracy: 1e-10)
    }
}

final class FITSRenderEngineTests: XCTestCase {

    func testRenderProducesCGImage() {
        let pixels: [Float] = (0..<(10 * 10)).map { Float($0) }
        let params = FITSRenderParams(minCut: 0, maxCut: 99, stretch: .linear, colormap: .grayscale)
        let image = FITSRenderEngine.render(pixels: pixels, width: 10, height: 10, params: params)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 10)
        XCTAssertEqual(image?.height, 10)
    }

    func testRenderWithLogStretch() {
        let pixels: [Float] = (0..<(4 * 4)).map { Float($0) }
        let params = FITSRenderParams(minCut: 0, maxCut: 15, stretch: .log, colormap: .grayscale)
        let image = FITSRenderEngine.render(pixels: pixels, width: 4, height: 4, params: params)
        XCTAssertNotNil(image)
    }

    func testRenderWithHeatColormap() {
        let pixels: [Float] = (0..<(4 * 4)).map { Float($0) }
        let params = FITSRenderParams(minCut: 0, maxCut: 15, stretch: .linear, colormap: .heat)
        let image = FITSRenderEngine.render(pixels: pixels, width: 4, height: 4, params: params)
        XCTAssertNotNil(image)
    }

    func testRenderEmptyReturnsNil() {
        let image = FITSRenderEngine.render(pixels: [], width: 0, height: 0, params: FITSRenderParams())
        XCTAssertNil(image)
    }

    func testRenderZeroRangeReturnsNil() {
        let pixels: [Float] = [5, 5, 5, 5]
        let params = FITSRenderParams(minCut: 5, maxCut: 5)
        let image = FITSRenderEngine.render(pixels: pixels, width: 2, height: 2, params: params)
        XCTAssertNil(image)
    }
}

final class FITSParserTests: XCTestCase {

    func testAutoCutBasic() {
        let pixels: [Float] = (0..<1000).map { Float($0) }
        let (min, max) = FITSParser.autoCut(pixels: pixels)
        // With 0.5% / 99.5% percentiles on 0..999:
        XCTAssertTrue(min < 10, "Min cut should be near 0, got \(min)")
        XCTAssertTrue(max > 990, "Max cut should be near 999, got \(max)")
    }

    func testAutoCutWithNaN() {
        var pixels: [Float] = (0..<100).map { Float($0) }
        pixels[50] = .nan
        pixels[51] = .infinity
        let (min, max) = FITSParser.autoCut(pixels: pixels)
        XCTAssertTrue(min.isFinite)
        XCTAssertTrue(max.isFinite)
    }

    func testAutoCutAllSame() {
        let pixels: [Float] = [Float](repeating: 42, count: 100)
        let (min, max) = FITSParser.autoCut(pixels: pixels)
        XCTAssertEqual(min, 42)
        XCTAssertEqual(max, 42)
    }
}

final class FITSHeaderTests: XCTestCase {

    func testAddAndRetrieve() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "16", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "1024", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "2048", comment: ""))

        XCTAssertEqual(header.bitpix, 16)
        XCTAssertEqual(header.naxis, 2)
        XCTAssertEqual(header.naxis1, 1024)
        XCTAssertEqual(header.naxis2, 2048)
    }

    func testBscaleBzeroDefaults() {
        let header = FITSHeader()
        XCTAssertEqual(header.bscale, 1.0)
        XCTAssertEqual(header.bzero, 0.0)
    }

    func testStringValue() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN'", comment: ""))
        XCTAssertEqual(header.string("CTYPE1"), "RA---TAN")
    }
}
