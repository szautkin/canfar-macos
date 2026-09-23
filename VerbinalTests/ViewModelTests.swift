// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import simd
@testable import Verbinal
import VerbinalKit

// MARK: - DataTrainModel Tests

@MainActor
final class DataTrainModelTests: XCTestCase {

    private func makeModel() -> DataTrainModel {
        let service = DataTrainService(tapClient: TAPClient())
        return DataTrainModel(dataTrainService: service)
    }

    func testFilteredOptionsEmptyRows() {
        let model = makeModel()
        let state = SearchFormState()
        let options = model.filteredOptions(for: 0, formState: state)
        XCTAssertEqual(options.count, 0)
    }

    func testClearDownstreamClearsAll() {
        let model = makeModel()
        let state = SearchFormState()
        state.selectedCollections = ["JWST"]
        state.selectedInstruments = ["NIRCam"]
        state.selectedFilters = ["F200W"]

        model.clearDownstream(from: 1, formState: state) // clear from column 1 (collection)

        XCTAssertEqual(state.selectedInstruments, [], "Instruments should be cleared")
        XCTAssertEqual(state.selectedFilters, [], "Filters should be cleared")
        XCTAssertEqual(state.selectedCollections, ["JWST"], "Collection should remain")
    }
}

// MARK: - FITSViewerModel Tests

@MainActor
final class FITSViewerModelTests: XCTestCase {

    func testResetViewport() {
        let model = FITSViewerModel()
        model.viewport.zoom = 5.0
        model.viewport.panX = 100
        model.viewport.panY = 200
        model.viewport.rotation = 1.5

        model.resetViewport()

        XCTAssertEqual(model.viewport.zoom, 1.0)
        XCTAssertEqual(model.viewport.panX, 0)
        XCTAssertEqual(model.viewport.panY, 0)
        XCTAssertEqual(model.viewport.rotation, 0)
    }

    func testPlaceCrosshairSetsValues() {
        let model = FITSViewerModel()
        // Set up minimal state
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "-32", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "100", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "100", comment: ""))

        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 40000, wcs: nil)
        model.file = FITSFile(url: URL(fileURLWithPath: "/tmp/test.fits"), hdus: [hdu])
        model.selectedHDUIndex = 0
        model.pixels = [Float](repeating: 42.0, count: 10000)

        model.placeCrosshair(at: CGPoint(x: 50, y: 50))

        XCTAssertNotNil(model.crosshairPixel)
        XCTAssertEqual(model.crosshairValue, "42", "Should show pixel value")
    }

    func testProbePixelUsesFITSArrayCoordinatesNotDisplayY() throws {
        // QA 1.2: probe_fits_pixel must match astropy origin=0. Applying the
        // canvas Y-flip here puts the far corner ~naxis2 pixels off (~130″ on
        // a JWST i2d) while get_fits_wcs (header path) stays correct.
        let angle = 61.47 * .pi / 180.0
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model, wcsCards: [
            ("CRPIX1", "51"), ("CRPIX2", "51"),
            ("CRVAL1", "80.0"), ("CRVAL2", "-69.0"),
            ("CDELT1", "-8.6e-6"), ("CDELT2", "8.6e-6"),
            ("PC1_1", "\(cos(angle))"), ("PC1_2", "\(-sin(angle))"),
            ("PC2_1", "\(sin(angle))"), ("PC2_2", "\(cos(angle))"),
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
        ])
        let wcs = try XCTUnwrap(model.wcs)

        let probe = try XCTUnwrap(model.probePixel(x: 0, y: 0))
        let expected = wcs.pixelToWorld(x: 0, y: 0)
        let displayFlipped = wcs.pixelToWorld(x: 0, y: 99)
        XCTAssertEqual(probe.ra!, expected.ra, accuracy: 1e-12)
        XCTAssertEqual(probe.dec!, expected.dec, accuracy: 1e-12)
        XCTAssertGreaterThan(abs(probe.ra! - displayFlipped.ra), 1e-8,
                             "probe must not apply the canvas Y-flip")
        XCTAssertEqual(probe.value, 0, "value is the FITS-order buffer at (0,0)")

        let centre = try XCTUnwrap(model.probePixel(x: 50, y: 50))
        XCTAssertEqual(centre.ra!, 80.0, accuracy: 1e-10)
        XCTAssertEqual(centre.dec!, -69.0, accuracy: 1e-10)
    }

    func testArrayPixelFlipsTheDisplayRow() {
        // Display row 0 is drawn from the LAST stored row; fractional
        // positions inside a drawn pixel resolve to that pixel.
        XCTAssertTrue(FITSViewerModel.arrayPixel(atDisplay: CGPoint(x: 0, y: 0), naxis2: 100) == (0, 99))
        XCTAssertTrue(FITSViewerModel.arrayPixel(atDisplay: CGPoint(x: 7.9, y: 10.7), naxis2: 100) == (7, 89))
        XCTAssertTrue(FITSViewerModel.arrayPixel(atDisplay: CGPoint(x: 99.5, y: 99.5), naxis2: 100) == (99, 0))
    }

    func testCanvasReadoutsShowTheDrawnPixelNotTheMirroredRow() {
        // The renderer draws buffer row `naxis2 - 1 - displayRow`. The
        // crosshair / hover values must read that row — before, they read
        // buffer row `displayRow` while RA/Dec used the flipped row.
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model)
        let topLeft = CGPoint(x: 2, y: 0)
        let drawn = FITSViewerModel.formatPixelValue(FITSTestFixtures.rampValue(x: 2, y: 99))

        model.placeCrosshair(at: topLeft)
        XCTAssertEqual(model.crosshairValue, drawn)

        model.updateCursorInfo(at: topLeft)
        XCTAssertEqual(model.cursorPixelValue, drawn)

        let probe = model.probePixel(x: 2, y: 99)
        XCTAssertEqual(probe?.value.map { Float($0) }, FITSTestFixtures.rampValue(x: 2, y: 99),
                       "canvas and probe_fits_pixel agree on the same pixel")
    }

    func testRenderImageWithPixels() {
        let model = FITSViewerModel()
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "-32", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "4", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "4", comment: ""))

        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 64, wcs: nil)
        model.file = FITSFile(url: URL(fileURLWithPath: "/tmp/test.fits"), hdus: [hdu])
        model.selectedHDUIndex = 0
        model.pixels = (0..<16).map { Float($0) }
        model.renderParams.minCut = 0
        model.renderParams.maxCut = 15

        // Test the render engine directly since renderImage() is now async
        let image = FITSRenderEngine.render(
            pixels: model.pixels, width: 4, height: 4, params: model.renderParams
        )
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 4)
        XCTAssertEqual(image?.height, 4)
    }
}

// MARK: - FITSWCSTransform Additional Tests

final class FITSWCSTransformAdditionalTests: XCTestCase {

    func testFromHeaderWithCDMatrix() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "CRPIX1", value: "512", comment: ""))
        header.add(FITSCard(keyword: "CRPIX2", value: "512", comment: ""))
        header.add(FITSCard(keyword: "CRVAL1", value: "180.0", comment: ""))
        header.add(FITSCard(keyword: "CRVAL2", value: "45.0", comment: ""))
        header.add(FITSCard(keyword: "CD1_1", value: "0.000277778", comment: "")) // ~1 arcsec
        header.add(FITSCard(keyword: "CD1_2", value: "0.0", comment: ""))
        header.add(FITSCard(keyword: "CD2_1", value: "0.0", comment: ""))
        header.add(FITSCard(keyword: "CD2_2", value: "0.000277778", comment: ""))

        let wcs = FITSWCSTransform.fromHeader(header)
        XCTAssertNotNil(wcs)
        XCTAssertTrue(wcs!.isValid)
        XCTAssertEqual(wcs!.pixelScaleArcsec, 1.0, accuracy: 0.01)
    }

    func testFromHeaderWithCDELT() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "CRPIX1", value: "256", comment: ""))
        header.add(FITSCard(keyword: "CRPIX2", value: "256", comment: ""))
        header.add(FITSCard(keyword: "CRVAL1", value: "90.0", comment: ""))
        header.add(FITSCard(keyword: "CRVAL2", value: "30.0", comment: ""))
        header.add(FITSCard(keyword: "CDELT1", value: "-0.000277778", comment: ""))
        header.add(FITSCard(keyword: "CDELT2", value: "0.000277778", comment: ""))
        header.add(FITSCard(keyword: "CROTA2", value: "0.0", comment: ""))

        let wcs = FITSWCSTransform.fromHeader(header)
        XCTAssertNotNil(wcs)
        XCTAssertTrue(wcs!.isValid)
    }

    func testFromHeaderNoWCS() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "16", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))

        let wcs = FITSWCSTransform.fromHeader(header)
        XCTAssertNil(wcs)
    }

    func testNorthAngleWithRotation() {
        // CD matrix with 45-degree rotation
        let angle = 45.0 * .pi / 180.0
        let scale = 1.0 / 3600.0
        let cd = simd_double2x2(columns: (
            simd_double2(scale * cos(angle), scale * sin(angle)),
            simd_double2(-scale * sin(angle), scale * cos(angle))
        ))
        let wcs = FITSWCSTransform(
            crpix1: 0, crpix2: 0, crval1: 0, crval2: 0,
            cd: cd, cdInv: simd_inverse(cd),
            ctype1: "RA---TAN", ctype2: "DEC--TAN"
        )
        XCTAssertEqual(abs(wcs.northAngle), 45.0, accuracy: 0.1)
    }

    func testFromHeaderPCMatrixAppliesRotation() throws {
        // JWST i2d shape: PC + CDELT, no CD. A ~10° rotation must survive;
        // the old CDELT+CROTA2 fallback silently zeroed it.
        var header = FITSHeader()
        header.add(FITSCard(keyword: "CRPIX1", value: "1024", comment: ""))
        header.add(FITSCard(keyword: "CRPIX2", value: "1024", comment: ""))
        header.add(FITSCard(keyword: "CRVAL1", value: "80.0", comment: ""))
        header.add(FITSCard(keyword: "CRVAL2", value: "-69.0", comment: ""))
        header.add(FITSCard(keyword: "CDELT1", value: "-8.6e-6", comment: ""))
        header.add(FITSCard(keyword: "CDELT2", value: "8.6e-6", comment: ""))
        let angle = 10.0 * .pi / 180.0
        header.add(FITSCard(keyword: "PC1_1", value: "\(cos(angle))", comment: ""))
        header.add(FITSCard(keyword: "PC1_2", value: "\(-sin(angle))", comment: ""))
        header.add(FITSCard(keyword: "PC2_1", value: "\(sin(angle))", comment: ""))
        header.add(FITSCard(keyword: "PC2_2", value: "\(cos(angle))", comment: ""))
        header.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN'", comment: ""))
        header.add(FITSCard(keyword: "CTYPE2", value: "'DEC--TAN'", comment: ""))

        let wcs = try XCTUnwrap(FITSWCSTransform.fromHeader(header))
        XCTAssertTrue(wcs.isValid)
        XCTAssertEqual(abs(wcs.northAngle), 10.0, accuracy: 0.05)

        // Equivalent CD header must agree at the far corner — that's where a
        // missing rotation is 40–90″ on a JWST frame.
        var cdHeader = FITSHeader()
        cdHeader.add(FITSCard(keyword: "CRPIX1", value: "1024", comment: ""))
        cdHeader.add(FITSCard(keyword: "CRPIX2", value: "1024", comment: ""))
        cdHeader.add(FITSCard(keyword: "CRVAL1", value: "80.0", comment: ""))
        cdHeader.add(FITSCard(keyword: "CRVAL2", value: "-69.0", comment: ""))
        let cdelt1 = -8.6e-6, cdelt2 = 8.6e-6
        cdHeader.add(FITSCard(keyword: "CD1_1", value: "\(cdelt1 * cos(angle))", comment: ""))
        cdHeader.add(FITSCard(keyword: "CD1_2", value: "\(cdelt1 * -sin(angle))", comment: ""))
        cdHeader.add(FITSCard(keyword: "CD2_1", value: "\(cdelt2 * sin(angle))", comment: ""))
        cdHeader.add(FITSCard(keyword: "CD2_2", value: "\(cdelt2 * cos(angle))", comment: ""))
        cdHeader.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN'", comment: ""))
        cdHeader.add(FITSCard(keyword: "CTYPE2", value: "'DEC--TAN'", comment: ""))
        let fromCD = try XCTUnwrap(FITSWCSTransform.fromHeader(cdHeader))
        let pcSky = wcs.pixelToWorld(x: 0, y: 0)
        let cdSky = fromCD.pixelToWorld(x: 0, y: 0)
        XCTAssertEqual(pcSky.ra, cdSky.ra, accuracy: 1e-10)
        XCTAssertEqual(pcSky.dec, cdSky.dec, accuracy: 1e-10)

        // Without PC the same CDELT would report northAngle ≈ 0.
        var noPC = FITSHeader()
        noPC.add(FITSCard(keyword: "CRPIX1", value: "1024", comment: ""))
        noPC.add(FITSCard(keyword: "CRPIX2", value: "1024", comment: ""))
        noPC.add(FITSCard(keyword: "CRVAL1", value: "80.0", comment: ""))
        noPC.add(FITSCard(keyword: "CRVAL2", value: "-69.0", comment: ""))
        noPC.add(FITSCard(keyword: "CDELT1", value: "-8.6e-6", comment: ""))
        noPC.add(FITSCard(keyword: "CDELT2", value: "8.6e-6", comment: ""))
        noPC.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN'", comment: ""))
        noPC.add(FITSCard(keyword: "CTYPE2", value: "'DEC--TAN'", comment: ""))
        let unrotated = try XCTUnwrap(FITSWCSTransform.fromHeader(noPC))
        let unrotSky = unrotated.pixelToWorld(x: 0, y: 0)
        let dRaArcsec = abs(pcSky.ra - unrotSky.ra) * 3600 * cos(-69.0 * .pi / 180)
        let dDecArcsec = abs(pcSky.dec - unrotSky.dec) * 3600
        let offset = hypot(dRaArcsec, dDecArcsec)
        XCTAssertGreaterThan(offset, 5, "missing PC rotation must move the far corner by several arcsec")
    }

    func testFromHeaderCDWinsOverPC() throws {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "CRPIX1", value: "1", comment: ""))
        header.add(FITSCard(keyword: "CRPIX2", value: "1", comment: ""))
        header.add(FITSCard(keyword: "CRVAL1", value: "0", comment: ""))
        header.add(FITSCard(keyword: "CRVAL2", value: "0", comment: ""))
        header.add(FITSCard(keyword: "CD1_1", value: "-0.001", comment: ""))
        header.add(FITSCard(keyword: "CD1_2", value: "0", comment: ""))
        header.add(FITSCard(keyword: "CD2_1", value: "0", comment: ""))
        header.add(FITSCard(keyword: "CD2_2", value: "0.001", comment: ""))
        header.add(FITSCard(keyword: "CDELT1", value: "-1", comment: ""))
        header.add(FITSCard(keyword: "CDELT2", value: "1", comment: ""))
        header.add(FITSCard(keyword: "PC1_1", value: "0", comment: ""))
        header.add(FITSCard(keyword: "PC1_2", value: "-1", comment: ""))
        header.add(FITSCard(keyword: "PC2_1", value: "1", comment: ""))
        header.add(FITSCard(keyword: "PC2_2", value: "0", comment: ""))
        header.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN'", comment: ""))
        header.add(FITSCard(keyword: "CTYPE2", value: "'DEC--TAN'", comment: ""))
        let wcs = try XCTUnwrap(FITSWCSTransform.fromHeader(header))
        XCTAssertEqual(wcs.northAngle, 0, accuracy: 0.01, "CD must win when both CD and PC are present")
        XCTAssertEqual(wcs.pixelScaleArcsec, 3.6, accuracy: 0.01)
    }

    func testNinetyDegreeRotationIsValid() throws {
        // CROTA2=90 zeros the CD diagonal; the old isValid AND-of-diagonals
        // rejected this as degenerate.
        var header = FITSHeader()
        header.add(FITSCard(keyword: "CRPIX1", value: "50", comment: ""))
        header.add(FITSCard(keyword: "CRPIX2", value: "50", comment: ""))
        header.add(FITSCard(keyword: "CRVAL1", value: "10", comment: ""))
        header.add(FITSCard(keyword: "CRVAL2", value: "20", comment: ""))
        header.add(FITSCard(keyword: "CDELT1", value: "-0.001", comment: ""))
        header.add(FITSCard(keyword: "CDELT2", value: "0.001", comment: ""))
        header.add(FITSCard(keyword: "CROTA2", value: "90", comment: ""))
        header.add(FITSCard(keyword: "CTYPE1", value: "'RA---TAN'", comment: ""))
        header.add(FITSCard(keyword: "CTYPE2", value: "'DEC--TAN'", comment: ""))
        let wcs = try XCTUnwrap(FITSWCSTransform.fromHeader(header))
        XCTAssertTrue(wcs.isValid)
        XCTAssertEqual(abs(wcs.northAngle), 90.0, accuracy: 0.1)
    }
}

// MARK: - SearchFormModel Basic Tests

@MainActor
final class SearchFormModelBasicTests: XCTestCase {

    func testResetClearsAllFields() {
        let model = SearchFormModel()
        model.formState.target = "M31"
        model.formState.piName = "Smith"
        model.formState.selectedCollections = ["JWST"]

        model.resetForm()

        XCTAssertEqual(model.formState.target, "")
        XCTAssertEqual(model.formState.piName, "")
        XCTAssertEqual(model.formState.selectedCollections, [])
        XCTAssertEqual(model.resolverStatus, .idle)
    }

    func testInitialState() {
        let model = SearchFormModel()
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.searchError)
        XCTAssertEqual(model.selectedTab, .search)
        XCTAssertEqual(model.resultsModel.totalRows, 0)
    }

    func testTabSwitching() {
        let model = SearchFormModel()
        model.selectedTab = .results
        XCTAssertEqual(model.selectedTab, .results)
        model.selectedTab = .adql
        XCTAssertEqual(model.selectedTab, .adql)
    }
}
