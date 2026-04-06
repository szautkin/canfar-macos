// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import simd
@testable import Verbinal

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
