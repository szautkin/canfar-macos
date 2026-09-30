// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// A table that holds a spectrum is read as one, not drawn as an image of
/// its rows' bytes (plan 17 U4, QA N1: `oezt010e0_x1d.fits` was a blank
/// 38946×1 picture). Fixtures by `fixture-tools/make_spectrum_fixtures.py`.
final class FITSSpectrumTests: XCTestCase {

    private func fixture(_ name: String) throws -> (FITSFile, Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return (try FITSParser.parse(from: data), data)
    }

    func testATableIsNotAnImage() throws {
        let (file, _) = try fixture("x1d-echelle.fits")
        XCTAssertTrue(file.hdus[1].isTable)
        XCTAssertFalse(file.hdus[1].isImage)
        XCTAssertNil(file.firstImageHDU, "an _x1d has no image to draw")
    }

    func testTheTablesColumnsAreItsOwn() throws {
        let (file, data) = try fixture("x1d-echelle.fits")
        let table = try XCTUnwrap(FITSBinaryTable(header: file.hdus[1].header))
        XCTAssertEqual(table.columns.map(\.name), ["SPORDER", "WAVELENGTH", "FLUX", "ERROR", "DQ"])
        XCTAssertEqual(table.columns.map(\.count), [1, 8, 8, 8, 8])
        XCTAssertEqual(table.columns.map(\.offset), [0, 2, 66, 98, 130])
        XCTAssertEqual(table.rows, 2)
        let rows = data.subdata(in: file.hdus[1].dataOffset..<(file.hdus[1].dataOffset + table.rows * table.rowBytes))
        let orders = try XCTUnwrap(table.values(of: try XCTUnwrap(table.column(named: "sporder")), in: rows))
        XCTAssertEqual(orders, [[301], [300]])
        XCTAssertNil(FITSBinaryTable(header: file.hdus[0].header), "the primary HDU is no table")
    }

    /// An `_x1d`: an echelle order per row, each its own segment, in
    /// wavelength order, the NaN flux left out, with its errors and units.
    func testAnEchelleSpectrumIsASegmentPerOrder() throws {
        let (file, data) = try fixture("x1d-echelle.fits")
        guard case .spectrum(let spectrum) = FITSTableContent.read(file.hdus[1], in: data) else {
            return XCTFail("expected a spectrum")
        }
        XCTAssertEqual(spectrum.wavelengthColumn, "WAVELENGTH")
        XCTAssertEqual(spectrum.wavelengthUnit, "Angstroms")
        XCTAssertEqual(spectrum.fluxUnit, "erg/s/cm**2/Angstrom")
        XCTAssertEqual(spectrum.errorColumn, "ERROR")
        XCTAssertEqual(spectrum.segments.count, 2)
        XCTAssertEqual(spectrum.segments[0].wavelength.first, 1200.0)
        XCTAssertEqual(spectrum.segments[1].wavelength.count, 7, "the NaN flux is not a point")
        XCTAssertEqual(spectrum.pointCount, 15)
        XCTAssertEqual(spectrum.segments[0].flux[0], 1e-14, accuracy: 1e-20)
        XCTAssertEqual(try XCTUnwrap(spectrum.segments[0].error)[0], 5e-16, accuracy: 1e-21)
        XCTAssertEqual(try XCTUnwrap(spectrum.wavelengthRange).lowerBound, 1190.0)
    }

    /// A JWST `x1d`: a number per row, one segment; an integer column is
    /// read through its TSCAL and TZERO.
    func testARowPerPointSpectrumIsOneSegment() throws {
        let (file, data) = try fixture("x1d-rows.fits")
        guard case .spectrum(let spectrum) = FITSTableContent.read(file.hdus[1], in: data) else {
            return XCTFail("expected a spectrum")
        }
        XCTAssertEqual(spectrum.segments.count, 1)
        XCTAssertEqual(spectrum.pointCount, 20)
        XCTAssertEqual(spectrum.wavelengthUnit, "um")
        XCTAssertEqual(spectrum.errorColumn, "FLUX_ERROR")
        XCTAssertEqual(spectrum.segments[0].flux[0], 2e-3, accuracy: 1e-12)

        let table = try XCTUnwrap(FITSBinaryTable(header: file.hdus[1].header))
        let rows = data.subdata(in: file.hdus[1].dataOffset..<(file.hdus[1].dataOffset + table.rows * table.rowBytes))
        let scaled = try XCTUnwrap(table.values(of: try XCTUnwrap(table.column(named: "FLUXSCALED")), in: rows))
        XCTAssertEqual(scaled[0][0], 2e-3, accuracy: 1e-6)
    }

    func testATableWithNoSpectrumListsItsColumns() throws {
        let (file, data) = try fixture("table-no-spectrum.fits")
        XCTAssertEqual(FITSTableContent.read(file.hdus[1], in: data), .columns(["RA [deg]", "DEC [deg]", "MAG", "NAME"]))
        XCTAssertNil(FITSTableContent.read(file.hdus[0], in: data))
    }

    /// Plan 21 D4: how large the error is — 5% of the flux in the echelle
    /// fixture — so a plot can say so when its band is too thin to see.
    func testTheErrorsSizeIsMeasured() throws {
        let (file, data) = try fixture("x1d-echelle.fits")
        guard case .spectrum(let spectrum) = FITSTableContent.read(file.hdus[1], in: data) else {
            return XCTFail("expected a spectrum")
        }
        let size = try XCTUnwrap(spectrum.errorSize)
        XCTAssertEqual(size.ofFlux, 0.05, accuracy: 1e-6)
        XCTAssertGreaterThan(size.ofRange, 0)
        let (catalogue, catalogueData) = try fixture("x1d-rows.fits")
        guard case .spectrum(let noError) = FITSTableContent.read(catalogue.hdus[1], in: catalogueData) else {
            return XCTFail("expected a spectrum")
        }
        XCTAssertEqual(try XCTUnwrap(noError.errorSize).ofFlux, 0.01, accuracy: 1e-9)
    }

    func testBinningKeepsTheShapeInFewerPoints() throws {
        let (file, data) = try fixture("x1d-rows.fits")
        guard case .spectrum(let spectrum) = FITSTableContent.read(file.hdus[1], in: data) else {
            return XCTFail("expected a spectrum")
        }
        let binned = spectrum.binned(maxPoints: 5)
        XCTAssertEqual(binned.count, 1)
        XCTAssertEqual(binned[0].count, 5)
        XCTAssertEqual(binned[0][0].wavelength, (1.0 + 1.1 + 1.2 + 1.3) / 4, accuracy: 1e-9)
        XCTAssertNotNil(binned[0][0].error)
        XCTAssertEqual(spectrum.binned(maxPoints: 1000)[0].count, 20, "never more points than there are")
    }

    func testATFormSaysHowManyOfWhat() {
        XCTAssertEqual(FITSBinaryTable.parse(tform: "1024E")?.count, 1024)
        XCTAssertEqual(FITSBinaryTable.parse(tform: "D")?.type, "D")
        XCTAssertEqual(FITSBinaryTable.parse(tform: "1PE(1024)")?.type, "P")
        XCTAssertNil(FITSBinaryTable.parse(tform: "12Z"))
        XCTAssertEqual(FITSBinaryTable.width(type: "X", count: 9), 2)
    }
}
