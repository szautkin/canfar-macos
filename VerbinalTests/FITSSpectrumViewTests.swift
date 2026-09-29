// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// A spectrum table opens as a spectrum in the FITS viewer, and an
/// assistant reads it as plotted (plan 17 U4, QA N1: `oezt010e0_x1d.fits`
/// opened as a blank 38946×1 image).
@MainActor
final class FITSSpectrumViewTests: XCTestCase {

    func testAnX1DOpensAsASpectrumNotAnImage() async throws {
        let url = try FITSTestFixtures.writeSpectrumTable()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = FITSViewerModel()
        await model.open(url: url)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.isLoaded)
        XCTAssertNil(model.renderedImage, "no picture of the table's bytes")
        XCTAssertEqual(model.selectedHDUIndex, 1)
        let spectrum = try XCTUnwrap(model.table?.spectrum)
        XCTAssertEqual(spectrum.pointCount, 4)
        XCTAssertEqual(spectrum.wavelengthUnit, "Angstroms")
        XCTAssertEqual(model.viewableHDUs.map(\.label), ["HDU 1 [table SCI]"])
    }

    func testTheToolGivesTheSpectrumAsPlotted() async throws {
        let url = try FITSTestFixtures.writeSpectrumTable()
        defer { try? FileManager.default.removeItem(at: url) }
        let table = try AppState.table(in: url, hduIndex: nil)
        let tool = GetFITSSpectrumTool(read: { _, _ in table })
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let out = try await tool.handle(.init(maxPoints: 2), context: ctx)
        XCTAssertTrue(out.isSpectrum)
        XCTAssertEqual(out.hduIndex, 1)
        XCTAssertEqual(out.pointCount, 4)
        XCTAssertEqual(out.wavelengthRange, [5000, 5030])
        XCTAssertEqual(out.segments?.first?.count, 2, "binned to maxPoints")
        XCTAssertEqual(try XCTUnwrap(out.segments?.first?.first?.first), 5005, accuracy: 1e-9)
        XCTAssertThrowsError(try AppState.table(in: url, hduIndex: 0), "the primary HDU is no table")
    }

    func testAnAxisWritesTinyFluxesInAPowerOfTen() {
        XCTAssertEqual(SpectrumAxis.exponent(for: 3.3e-15...3.98e-14), -14)
        XCTAssertEqual(SpectrumAxis.exponent(for: 0.5...120), 0)
        XCTAssertEqual(SpectrumAxis.exponent(for: nil), 0)
        XCTAssertEqual(SpectrumAxis.title("Flux", unit: "erg/s/cm**2/Angstrom", exponent: -14),
                       "Flux (10^-14 erg/s/cm**2/Angstrom)")
        XCTAssertEqual(SpectrumAxis.title("Wavelength", unit: nil, exponent: 0), "Wavelength")
    }
}
