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
        let url = try FITSTestFixtures.writeCube()
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
}
