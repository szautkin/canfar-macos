// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Reference-value accuracy tests for the cube viewer's numbers and the
// rendering pipeline that produces publication figures. Every expected value is
// derived analytically (not from a prior run), so a regression in the math is
// caught immediately.

import XCTest
import CoreGraphics
@testable import VerbinalKit

final class CubeAccuracyTests: XCTestCase {

    // MARK: - Celestial WCS (TAN gnomonic)

    func testTANReferencePixelIsExact() {
        let wcs = CelestialWCS(valid: true, projection: .tan, frame: .equatorial,
                               crval1: 150, crval2: 2, crpix1: 1, crpix2: 1,
                               cd11: -0.001, cd12: 0, cd21: 0, cd22: 0.001)
        let ref = try? XCTUnwrap(wcs.pixelToSky(x: 0, y: 0))
        XCTAssertEqual(ref?.lon ?? .nan, 150, accuracy: 1e-9)
        XCTAssertEqual(ref?.lat ?? .nan, 2, accuracy: 1e-9)
    }

    func testTANOffsetMatchesInverseGnomonic() throws {
        let wcs = CelestialWCS(valid: true, projection: .tan, frame: .equatorial,
                               crval1: 150, crval2: 2, crpix1: 1, crpix2: 1,
                               cd11: -0.001, cd12: 0, cd21: 0, cd22: 0.001)
        let sky = try XCTUnwrap(wcs.pixelToSky(x: 100, y: 50))

        // Independent inverse-gnomonic reference.
        let d2r = Double.pi / 180
        let xi = (-0.001 * 100) * d2r      // dx = 100+1-1 = 100
        let eta = (0.001 * 50) * d2r        // dy = 50
        let ra0 = 150 * d2r, dec0 = 2 * d2r
        let den = cos(dec0) - eta * sin(dec0)
        var expRA = (ra0 + atan2(xi, den)) / d2r
        if expRA < 0 { expRA += 360 }
        let expDec = atan2(sin(dec0) + eta * cos(dec0), (xi * xi + den * den).squareRoot()) / d2r

        XCTAssertEqual(sky.lon, expRA, accuracy: 1e-9)
        XCTAssertEqual(sky.lat, expDec, accuracy: 1e-9)
        XCTAssertEqual(sky.lon, 149.9, accuracy: 1e-3)   // sanity: ~0.1° west
    }

    func testCARGalacticIsLinearAndLabeled() throws {
        let wcs = CelestialWCS(valid: true, projection: .car, frame: .galactic,
                               crval1: 30, crval2: 0, crpix1: 1, crpix2: 1,
                               cd11: -0.01, cd12: 0, cd21: 0, cd22: 0.01)
        let sky = try XCTUnwrap(wcs.pixelToSky(x: 10, y: 5))
        XCTAssertEqual(sky.lon, 29.9, accuracy: 1e-9)   // 30 + (-0.01 * 10)
        XCTAssertEqual(sky.lat, 0.05, accuracy: 1e-9)   // 0 + 0.01 * 5
        let readout = wcs.formatSky(lon: sky.lon, lat: sky.lat)
        XCTAssertEqual(readout.lonLabel, "GLON")
        XCTAssertEqual(readout.latLabel, "GLAT")
    }

    // MARK: - Spectral conversions

    func testFreqToRadioVelocityIsExact() {
        let spec = SpectralWCS(ctype: "FREQ", cunit: "Hz", restfrq: 1e9, table: nil, crval: 1e9, crpix: 1, cdelt: 1e6)
        XCTAssertEqual(spec.value(atChannel: 0), 1e9, accuracy: 1)
        XCTAssertEqual(spec.value(atChannel: 10), 1.01e9, accuracy: 1)

        let readout = spec.format(channel: 10)
        XCTAssertEqual(readout.primary, "1.01000 GHz")
        XCTAssertEqual(readout.axisLabel, "VELOCITY km/s")
        let expectedVel = 299792.458 * (1 - 1.01e9 / 1e9)   // = -2997.92458
        XCTAssertEqual(readout.secondary, String(format: "%.2f km/s", expectedVel))
    }

    func testWavenumberToNanometres() {
        let spec = SpectralWCS(ctype: "WAVN", cunit: "cm-1", restfrq: nil, table: nil, crval: 10000, crpix: 1, cdelt: 0)
        let readout = spec.format(channel: 0)
        XCTAssertEqual(readout.primary, String(format: "%.3f cm⁻¹", 10000.0))
        XCTAssertEqual(readout.secondary, String(format: "λ %.2f nm", 1000.0))   // 1e7 / 10000
    }

    func testWavelengthUnitConversions() {
        let metres = SpectralWCS(ctype: "WAVE", cunit: "m", restfrq: nil, table: nil, crval: 5e-6, crpix: 1, cdelt: 1e-7)
        XCTAssertEqual(metres.format(channel: 0).primary, String(format: "%.4f µm", 5.0))
        let angstrom = SpectralWCS(ctype: "WAVE", cunit: "angstrom", restfrq: nil, table: nil, crval: 50000, crpix: 1, cdelt: 1)
        XCTAssertEqual(angstrom.format(channel: 0).primary, String(format: "%.4f µm", 5.0))
    }

    func testWaveTabLookupUsesTable() {
        let table: [Double] = [1.0, 2.0, 3.5, 9.0]
        let spec = SpectralWCS(ctype: "WAVE-TAB", cunit: "um", restfrq: nil, table: table, crval: 0, crpix: 1, cdelt: 1)
        XCTAssertEqual(spec.value(atChannel: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(spec.value(atChannel: 2), 3.5, accuracy: 1e-12)
        XCTAssertEqual(spec.value(atChannel: 99), 9.0, accuracy: 1e-12)   // clamps to last
    }

    // MARK: - Statistics

    func testRobustPercentilesExact() {
        let values = (0..<1000).map { Float($0) }
        let stats = CubeModel.computeStats(values)
        XCTAssertEqual(stats.min, 0, accuracy: 1e-3)
        XCTAssertEqual(stats.max, 999, accuracy: 1e-3)
        XCTAssertEqual(stats.median, 500, accuracy: 1)
        XCTAssertEqual(stats.lo, 1, accuracy: 1)      // p0.1
        XCTAssertEqual(stats.hi, 998, accuracy: 1)    // p99.9
        XCTAssertEqual(stats.nanFrac, 0, accuracy: 1e-9)
    }

    // MARK: - Rendering pipeline (FITSRenderEngine)

    /// A linear grayscale ramp must map value → byte 1:1 (the property a
    /// publication figure relies on for an honest colorbar).
    func testLinearGrayscaleRampMapsValuesToBytes() throws {
        let pixels = (0..<256).map { Float($0) }
        let params = FITSRenderParams(minCut: 0, maxCut: 255, stretch: .linear, colormap: .grayscale)
        let image = try XCTUnwrap(FITSRenderEngine.render(pixels: pixels, width: 256, height: 1, params: params))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 1)

        let rgba = try pixelBytes(image)
        XCTAssertEqual(rgba[0 * 4], 0)            // min → black
        XCTAssertEqual(rgba[255 * 4], 255)        // max → white
        XCTAssertEqual(Double(rgba[64 * 4]), 64, accuracy: 1)
        XCTAssertEqual(Double(rgba[128 * 4]), 128, accuracy: 1)
        XCTAssertEqual(Double(rgba[192 * 4]), 192, accuracy: 1)
    }

    func testSqrtStretchAppliesAtMidpoint() throws {
        // value 0.25 of the range → sqrt → 0.5 → mid-gray.
        let params = FITSRenderParams(minCut: 0, maxCut: 255, stretch: .sqrt, colormap: .grayscale)
        let image = try XCTUnwrap(FITSRenderEngine.render(pixels: [63.75], width: 1, height: 1, params: params))
        let rgba = try pixelBytes(image)
        XCTAssertEqual(Double(rgba[0]), 127, accuracy: 2)   // sqrt(0.25)=0.5
    }

    func testNaNRendersAsFloor() throws {
        let params = FITSRenderParams(minCut: 0, maxCut: 1, stretch: .linear, colormap: .grayscale)
        let image = try XCTUnwrap(FITSRenderEngine.render(pixels: [Float.nan], width: 1, height: 1, params: params))
        let rgba = try pixelBytes(image)
        XCTAssertEqual(rgba[0], 0)   // NaN → 0 → colormap floor
    }

    func testColormapEndpointsMonotonicBrightness() {
        for cm in [FITSRenderParams.ColormapType.viridis, .inferno, .magma, .plasma] {
            let lut = FITSRenderEngine.colormapRGBA(cm)
            let darkSum = Int(lut[0]) + Int(lut[1]) + Int(lut[2])
            let brightSum = Int(lut[255 * 4]) + Int(lut[255 * 4 + 1]) + Int(lut[255 * 4 + 2])
            XCTAssertLessThan(darkSum, brightSum, "\(cm.rawValue): bright end should be brighter than dark end")
            XCTAssertEqual(lut[3], 255)   // opaque
        }
        let gray = FITSRenderEngine.colormapRGBA(.grayscale)
        XCTAssertEqual(gray[0], 0)
        XCTAssertEqual(gray[255 * 4], 255)
    }

    // MARK: - Helpers

    /// Read an image's RGBA bytes by redrawing into a known RGBA8 context.
    private func pixelBytes(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
}
