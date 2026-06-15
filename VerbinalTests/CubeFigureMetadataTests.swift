// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// End-to-end validation of the publication figure's legend: load a known
// synthetic cube into CubeViewerModel and assert the figure metadata.

import XCTest
@testable import Verbinal
import VerbinalKit

@MainActor
final class CubeFigureMetadataTests: XCTestCase {

    func testFigureMetadataFromKnownCube() async throws {
        let url = try writeSyntheticCube()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = CubeViewerModel()
        await model.open(url: url)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.hasData)

        let meta = model.figureMetadata()
        XCTAssertEqual(meta.title, "TestObj")
        XCTAssertEqual(meta.dimensions, "4 × 3 × 5")
        XCTAssertEqual(meta.unit, "Jy")
        XCTAssertEqual(meta.mode, "Resident")
        XCTAssertEqual(meta.nan, "0.0%")
        XCTAssertEqual(meta.lonLabel, "RA")
        XCTAssertEqual(meta.latLabel, "DEC")
        XCTAssertEqual(meta.channelLabel, "CH 3/5")      // default channel = nz/2 = 2
        XCTAssertNotNil(meta.raRange)
        XCTAssertNotNil(meta.decRange)
        // Spectral axis is FREQ 1.000…1.004 GHz over 5 channels.
        XCTAssertEqual(meta.spectralRange, "1.00000 GHz … 1.00400 GHz")
        XCTAssertFalse(meta.valueLo.isEmpty)
        XCTAssertFalse(meta.valueHi.isEmpty)
    }

    // MARK: - Synthetic FITS cube on disk

    private func writeSyntheticCube() throws -> URL {
        let nx = 4, ny = 3, nz = 5
        var data = Data()
        for z in 0..<nz {
            for y in 0..<ny {
                for x in 0..<nx {
                    var be = Float(z * 100 + y * 10 + x).bitPattern.bigEndian
                    data.append(Data(bytes: &be, count: 4))
                }
            }
        }
        let cards: [(String, String)] = [
            ("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "3"),
            ("NAXIS1", "\(nx)"), ("NAXIS2", "\(ny)"), ("NAXIS3", "\(nz)"),
            ("OBJECT", "'TestObj'"), ("BUNIT", "'Jy'"),
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
            ("CRVAL1", "150.0"), ("CRVAL2", "2.0"), ("CRPIX1", "2.0"), ("CRPIX2", "1.5"),
            ("CD1_1", "-0.001"), ("CD2_2", "0.001"),
            ("CTYPE3", "'FREQ'"), ("CUNIT3", "'Hz'"),
            ("CRVAL3", "1000000000.0"), ("CRPIX3", "1.0"), ("CDELT3", "1000000.0"),
            ("RESTFRQ", "1000000000.0"),
        ]
        var header = ""
        for (k, v) in cards {
            let key = k.padding(toLength: 8, withPad: " ", startingAt: 0)
            header += String((key + "= " + v).prefix(80)).padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)

        var bytes = Data(header.utf8)
        pad(&bytes, with: 0x20)   // space-pad header to 2880
        pad(&data, with: 0x00)    // zero-pad data to 2880
        bytes.append(data)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cubefig-\(UUID().uuidString).fits")
        try bytes.write(to: url)
        return url
    }

    private func pad(_ data: inout Data, with byte: UInt8) {
        let rem = data.count % 2880
        if rem != 0 { data.append(Data(repeating: byte, count: 2880 - rem)) }
    }
}
