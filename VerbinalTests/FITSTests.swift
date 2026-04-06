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
        // 3600 pixels = 1 degree at 1 arcsec/pixel
        let (ra, dec) = wcs.pixelToWorld(x: 512 + 3600, y: 512)
        XCTAssertEqual(ra, 181.0, accuracy: 1e-10)
        XCTAssertEqual(dec, 45.0, accuracy: 1e-10)
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
