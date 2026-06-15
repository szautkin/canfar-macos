// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

// MARK: - In-memory test source + synthetic-FITS builders

private struct MemoryCubeSource: CubeDataSource {
    let name: String
    let bytes: Data
    var size: Int { bytes.count }
    func read(offset: Int, length: Int) async throws -> Data {
        let end = Swift.min(offset + length, bytes.count)
        return bytes.subdata(in: offset..<end)
    }
}

private func fitsCard(_ keyword: String, _ value: String) -> String {
    let k = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
    let body = k + "= " + value
    return String(body.prefix(80)).padding(toLength: 80, withPad: " ", startingAt: 0)
}

private func padded(_ data: Data, to block: Int, pad: UInt8) -> Data {
    var d = data
    let rem = d.count % block
    if rem != 0 { d.append(Data(repeating: pad, count: block - rem)) }
    return d
}

private func buildFITS(cards: [(String, String)], data: Data) -> Data {
    var header = ""
    for (k, v) in cards { header += fitsCard(k, v) }
    header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    var bytes = padded(header.data(using: .ascii)!, to: 2880, pad: 0x20) // space-pad header
    bytes.append(padded(data, to: 2880, pad: 0x00))                       // zero-pad data
    return bytes
}

private func beFloat32(_ v: Float) -> Data {
    var be = v.bitPattern.bigEndian
    return Data(bytes: &be, count: 4)
}

private func beInt16(_ v: Int16) -> Data {
    var be = UInt16(bitPattern: v).bigEndian
    return Data(bytes: &be, count: 2)
}

/// A 4×3×5 float cube with FREQ spectral axis (RESTFRQ set) and a TAN celestial
/// WCS. Voxel value = z*100 + y*10 + x.
private func makeFreqCube() -> MemoryCubeSource {
    let nx = 4, ny = 3, nz = 5
    var data = Data()
    for z in 0..<nz {
        for y in 0..<ny {
            for x in 0..<nx {
                data.append(beFloat32(Float(z * 100 + y * 10 + x)))
            }
        }
    }
    let cards: [(String, String)] = [
        ("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "3"),
        ("NAXIS1", "\(nx)"), ("NAXIS2", "\(ny)"), ("NAXIS3", "\(nz)"),
        ("CTYPE3", "'FREQ'"), ("CUNIT3", "'Hz'"),
        ("CRVAL3", "1000000000.0"), ("CRPIX3", "1.0"), ("CDELT3", "1000000.0"),
        ("RESTFRQ", "1000000000.0"),
        ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
        ("CRVAL1", "150.0"), ("CRVAL2", "2.0"),
        ("CRPIX1", "2.0"), ("CRPIX2", "1.5"),
        ("CD1_1", "-0.001"), ("CD2_2", "0.001"),
    ]
    return MemoryCubeSource(name: "freq.fits", bytes: buildFITS(cards: cards, data: data))
}

// MARK: - Tests

final class CubeModelTests: XCTestCase {

    func testParseExtractPlaneStatsAndVolume() async throws {
        let model = try await CubeModel.open(source: makeFreqCube())
        let dims = await model.dimensions
        XCTAssertEqual(dims.nx, 4)
        XCTAssertEqual(dims.ny, 3)
        XCTAssertEqual(dims.nz, 5)

        // Plane extraction (before ingest → streamed path): z=2 → 200 + y*10 + x.
        let plane2 = try await model.plane(2)
        XCTAssertEqual(plane2.count, 12)
        XCTAssertEqual(plane2[0], 200, accuracy: 1e-3)   // y=0, x=0
        XCTAssertEqual(plane2[5], 211, accuracy: 1e-3)   // y=1, x=1
        XCTAssertEqual(plane2[11], 223, accuracy: 1e-3)  // y=2, x=3

        try await model.ingest(max3D: 256) { _ in }

        let statsValue = await model.stats
        let stats = try XCTUnwrap(statsValue)
        XCTAssertEqual(stats.min, 0, accuracy: 1e-3)
        XCTAssertEqual(stats.max, 423, accuracy: 1e-3)   // z=4,y=2,x=3
        XCTAssertEqual(stats.nanFrac, 0, accuracy: 1e-6)

        let value = await model.valueAt(x: 1, y: 1, z: 3)
        XCTAssertEqual(value, 311, accuracy: 1e-3)

        let spectrumValue = await model.spectrum(x: 1, y: 1)
        let spectrum = try XCTUnwrap(spectrumValue)
        XCTAssertEqual(spectrum.count, 5)
        XCTAssertEqual(spectrum[3], 311, accuracy: 1e-3)

        let volumeValue = await model.volume
        let volume = try XCTUnwrap(volumeValue)
        XCTAssertEqual(volume.nx, 4)
        XCTAssertEqual(volume.ny, 3)
        XCTAssertEqual(volume.nz, 5)
        XCTAssertEqual(volume.data.count, 4 * 3 * 5)
        // Every voxel is finite here, so none should be the 0 sentinel.
        XCTAssertEqual(volume.data.filter { $0 > 0 }.count, 60)
    }

    func testSpectralAndCelestialWCS() async throws {
        let model = try await CubeModel.open(source: makeFreqCube())
        try await model.ingest(max3D: 256) { _ in }
        let wcsValue = await model.wcs
        let wcs = try XCTUnwrap(wcsValue)

        // FREQ axis: channel 0 → CRVAL3, channel 1 → +CDELT3.
        XCTAssertEqual(wcs.spectral.value(atChannel: 0), 1.0e9, accuracy: 1)
        XCTAssertEqual(wcs.spectral.value(atChannel: 1), 1.001e9, accuracy: 1)

        let readout = wcs.spectral.format(channel: 1)
        XCTAssertEqual(readout.axisLabel, "VELOCITY km/s")   // RESTFRQ present
        XCTAssertEqual(readout.primary, "1.00100 GHz")
        XCTAssertNotNil(readout.secondary)                   // radio velocity

        // Celestial TAN at the reference pixel (0-based: crpix-1) → exactly CRVAL.
        let sky = try XCTUnwrap(wcs.celestial.pixelToSky(x: 1.0, y: 0.5))
        XCTAssertEqual(sky.lon, 150.0, accuracy: 1e-6)
        XCTAssertEqual(sky.lat, 2.0, accuracy: 1e-6)
    }

    /// Exercises the shared `FITSParser.decodeSamples` path via a 16-bit cube:
    /// big-endian Int16, BLANK→NaN, and BSCALE/BZERO scaling.
    func testDecodeInt16WithBlankAndScale() async throws {
        let blank: Int16 = -32768
        let raw: [[Int16]] = [[100, 200, blank, 400], [1, 2, 3, 4]]
        var data = Data()
        for plane in raw { for v in plane { data.append(beInt16(v)) } }
        let cards: [(String, String)] = [
            ("SIMPLE", "T"), ("BITPIX", "16"), ("NAXIS", "3"),
            ("NAXIS1", "2"), ("NAXIS2", "2"), ("NAXIS3", "2"),
            ("BLANK", "-32768"), ("BSCALE", "2.0"), ("BZERO", "10.0"),
        ]
        let source = MemoryCubeSource(name: "i16.fits", bytes: buildFITS(cards: cards, data: data))

        let model = try await CubeModel.open(source: source)
        let p0 = try await model.plane(0)
        XCTAssertEqual(p0[0], 210, accuracy: 1e-3)   // 10 + 2*100
        XCTAssertEqual(p0[1], 410, accuracy: 1e-3)   // 10 + 2*200
        XCTAssertTrue(p0[2].isNaN)                   // BLANK → NaN
        XCTAssertEqual(p0[3], 810, accuracy: 1e-3)   // 10 + 2*400
    }

    func testRejectsTwoDimensionalImage() async throws {
        var data = Data()
        for _ in 0..<(8 * 8) { data.append(beFloat32(1.0)) }
        let cards: [(String, String)] = [
            ("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "2"),
            ("NAXIS1", "8"), ("NAXIS2", "8"),
        ]
        let source = MemoryCubeSource(name: "flat.fits", bytes: buildFITS(cards: cards, data: data))
        do {
            _ = try await CubeModel.open(source: source)
            XCTFail("Expected a 2D image to be rejected as a non-cube")
        } catch {
            // expected
        }
    }

    func testComputeStatsIsNaNAware() {
        var values = [Float](repeating: 0, count: 100)
        for i in 0..<100 { values[i] = Float(i) }
        values[10] = .nan
        values[20] = .nan
        let stats = CubeModel.computeStats(values)
        XCTAssertEqual(stats.min, 0, accuracy: 1e-3)
        XCTAssertEqual(stats.max, 99, accuracy: 1e-3)
        XCTAssertEqual(stats.nanFrac, 0.02, accuracy: 1e-6)
        XCTAssertFalse(stats.lo.isNaN)
        XCTAssertFalse(stats.hi.isNaN)
    }
}
