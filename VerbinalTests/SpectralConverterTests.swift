// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class SpectralConverterTests: XCTestCase {

    // MARK: - Same-dimension

    func testMetresToNanometres() {
        XCTAssertEqual(SpectralConverter.convert(metres: 5e-7, to: .nanometres) ?? 0, 500, accuracy: 1e-6)
    }

    func testMetresToAngstroms() {
        XCTAssertEqual(SpectralConverter.convert(metres: 5e-7, to: .angstroms) ?? 0, 5000, accuracy: 1e-4)
    }

    func testMetresToMicrometres() {
        XCTAssertEqual(SpectralConverter.convert(metres: 2.2e-6, to: .micrometres) ?? 0, 2.2, accuracy: 1e-9)
    }

    func testMetresToCentimetres() {
        XCTAssertEqual(SpectralConverter.convert(metres: 1e-2, to: .centimetres) ?? 0, 1, accuracy: 1e-12)
    }

    // MARK: - Cross-dimension

    func testMetresToHertzRadio() {
        // 21 cm radio line → ~1.42 GHz.
        let ghz = SpectralConverter.convert(metres: 0.21, to: .gigahertz) ?? 0
        XCTAssertEqual(ghz, 1.4276, accuracy: 1e-3)
    }

    func testMetresToHertzMicrowave() {
        // 1 mm → ~299.79 GHz
        let ghz = SpectralConverter.convert(metres: 1e-3, to: .gigahertz) ?? 0
        XCTAssertEqual(ghz, 299.7925, accuracy: 1e-3)
    }

    func testMetresToElectronVoltsOptical() {
        // 500 nm → ~2.48 eV
        let ev = SpectralConverter.convert(metres: 5e-7, to: .electronVolts) ?? 0
        XCTAssertEqual(ev, 2.48, accuracy: 0.01)
    }

    func testMetresToKiloElectronVoltsXray() {
        // 1 Å → ~12.4 keV
        let kev = SpectralConverter.convert(metres: 1e-10, to: .kiloElectronVolts) ?? 0
        XCTAssertEqual(kev, 12.4, accuracy: 0.1)
    }

    // MARK: - Guards

    func testZeroWavelengthReturnsNil() {
        XCTAssertNil(SpectralConverter.convert(metres: 0, to: .nanometres))
    }

    func testNegativeWavelengthReturnsNil() {
        XCTAssertNil(SpectralConverter.convert(metres: -1e-9, to: .nanometres))
    }

    func testInfiniteWavelengthReturnsNil() {
        XCTAssertNil(SpectralConverter.convert(metres: .infinity, to: .gigahertz))
    }

    // MARK: - Unit lookup

    func testUnitLookupByID() {
        XCTAssertEqual(SpectralUnit.unit(withID: "nm")?.label, "nm")
        XCTAssertEqual(SpectralUnit.unit(withID: "NM")?.label, "nm", "Lookup is case-insensitive")
        XCTAssertNil(SpectralUnit.unit(withID: "parsecs"))
    }

    func testAllContainsFourteenUnits() {
        // Sanity-check we haven't dropped a unit while refactoring.
        XCTAssertEqual(SpectralUnit.all.count, 14)
    }
}
