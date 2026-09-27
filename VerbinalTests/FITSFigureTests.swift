// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import CoreGraphics
import VerbinalKit
@testable import Verbinal

/// A FITS figure of a region, with the image's marks on it.
@MainActor
final class FITSFigureTests: XCTestCase {

    /// A 100×100 image, rendered; with a WCS, 1.008″ per pixel centred on pixel (50, 50).
    private func tab(wcs: Bool = true) -> FITSViewerModel {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model, wcsCards: wcs ? [
            ("CRPIX1", "51"), ("CRPIX2", "51"), ("CRVAL1", "80.0"), ("CRVAL2", "-69.0"),
            ("CDELT1", "-2.8e-4"), ("CDELT2", "2.8e-4"),
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
        ] : [])
        model.renderedImage = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage()
        return model
    }

    private func pixelCircle(_ id: String, x: Double, y: Double, radius: Double) -> Mark {
        Mark(id: id, kind: .circle, anchor: .init(space: .imagePixel, x: x, y: y), extent: .square(radius),
             author: .user, createdAt: Date())
    }

    private func problem(_ body: () throws -> Void) -> FITSFigureProblem.Kind? {
        do { try body() } catch { return (error as? FITSFigureProblem)?.kind }
        return nil
    }

    // MARK: - Regions

    func testABoxIsInFITSPixelsWithRowsGoingUp() throws {
        let rect = try tab().figureRect(.box(x: 10, y: 20, width: 30, height: 40), marks: [])
        XCTAssertEqual(rect, CGRect(x: 10, y: 40, width: 30, height: 40), "bottom row 20 is display row 79")
        XCTAssertEqual(try tab().figureRect(.image, marks: []), CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testTheViewIsWhatIsOnScreen() throws {
        let model = tab()
        model.lastCanvasSize = CGSize(width: 800, height: 600)
        model.viewport.zoom = 8
        let rect = try model.figureRect(.view, marks: [])
        XCTAssertEqual(rect.width, 100)
        XCTAssertEqual(rect.height, 76, accuracy: 1, "600 pt at 8 pt per pixel, on whole pixels")
        XCTAssertEqual(rect.midY, 50, accuracy: 0.5)
    }

    func testASkyCircleIsFramedByItsSquare() throws {
        let rect = try tab().figureRect(.sky(raDeg: 80, decDeg: -69, radiusDeg: 10 / 3600.0), marks: [])
        XCTAssertEqual(rect.midX, 50.5, accuracy: 1)
        XCTAssertEqual(rect.midY, 49.5, accuracy: 1)
        XCTAssertEqual(rect.width, 20, accuracy: 2, "10″ at 1.008″ per pixel, each way")
    }

    func testAMarkIsFramedWithRoomForItsLabel() throws {
        let rect = try tab().figureRect(.mark(id: "m1"), marks: [pixelCircle("m1", x: 50, y: 50, radius: 5)])
        XCTAssertEqual(rect.width, 64, accuracy: 1, "a small mark gets the minimum frame")
        XCTAssertTrue(rect.contains(CGPoint(x: 50.5, y: 49.5)))
        let big = try tab().figureRect(.mark(id: "m2"), marks: [pixelCircle("m2", x: 50, y: 50, radius: 15)])
        XCTAssertEqual(big.width, 90, accuracy: 1, "three times its size")
    }

    func testRegionsThatCannotBeShownSayWhy() {
        XCTAssertEqual(problem { _ = try tab().figureRect(.box(x: 500, y: 500, width: 10, height: 10), marks: []) }, .badRegion)
        XCTAssertEqual(problem { _ = try tab().figureRect(.mark(id: "nope"), marks: []) }, .noMark)
        XCTAssertEqual(problem { _ = try tab(wcs: false).figureRect(.sky(raDeg: 80, decDeg: -69, radiusDeg: 0.01), marks: []) }, .badRegion)
        XCTAssertEqual(problem { _ = try FITSViewerModel().figureRect(.image, marks: []) }, .nothingOpen)
    }

    // MARK: - The figure

    /// The legend's centre is the region's, not the WCS reference pixel.
    func testTheLegendDescribesTheRegion() throws {
        let model = tab()
        let rect = try model.figureRect(.box(x: 0, y: 0, width: 20, height: 20), marks: [])
        let legend = Dictionary(uniqueKeysWithValues: model.figureLegend(for: rect))
        let wcs = try XCTUnwrap(model.wcs)
        let centre = wcs.pixelToWorld(x: 9.5, y: 9.5)
        XCTAssertEqual(legend["Center"], "\(Sexagesimal.readoutHMS(degrees: centre.ra)) \(Sexagesimal.readoutDMS(degrees: centre.dec))")
        XCTAssertEqual(legend["Size"], "20 × 20 px of 100 × 100")
        XCTAssertEqual(legend["Field"], "20.2″ × 20.2″")
    }

    func testTheFigureCutsTheRegionAndPutsMarksOnTheirPixels() throws {
        let model = tab()
        let mark = pixelCircle("m1", x: 25, y: 70, radius: 2)
        let figure = try model.figure(.box(x: 10, y: 50, width: 40, height: 40), marks: [mark])
        XCTAssertEqual(figure.content.width, 40)
        XCTAssertEqual(figure.content.height, 40)
        // Drawn 400 pt wide: 10 pt per pixel. FITS (25, 70) is display (25.5, 29.5); the box starts at (10, 10).
        let projection = try XCTUnwrap(figure.markProjection(width: 400))
        let point = try XCTUnwrap(projection.point(mark.anchor))
        XCTAssertEqual(point.x, 155, accuracy: 1e-9)
        XCTAssertEqual(point.y, 195, accuracy: 1e-9)
        XCTAssertEqual(projection.halfSize(.square(2), mark.anchor)?.width, 20)
    }

    // MARK: - The tool

    private func request(_ json: String) throws -> FITSFigureRequest {
        try ExportFITSFigureTool.request(from: JSONDecoder().decode(ExportFITSFigureTool.Args.self, from: Data(json.utf8)))
    }

    func testTheToolReadsARegionAndRefusesAnotherRegionsArguments() throws {
        XCTAssertEqual(try request("{}").region, .view)
        XCTAssertEqual(try request(#"{"region":"box","x":1,"y":2,"width":3,"height":4,"format":"pdf"}"#),
                       FITSFigureRequest(scale: 2, format: .pdf, region: .box(x: 1, y: 2, width: 3, height: 4)))
        XCTAssertEqual(try request(#"{"region":"mark","markId":"m3","marks":false}"#).marks, false)
        XCTAssertThrowsError(try request(#"{"region":"box","x":1}"#))
        XCTAssertThrowsError(try request(#"{"region":"view","markId":"m3"}"#), "a stray markId is a mistake")
        XCTAssertThrowsError(try request(#"{"region":"sky","raDeg":1,"decDeg":95,"radiusDeg":1}"#))
        XCTAssertThrowsError(try request(#"{"scale":8}"#))
    }

    /// A proposal waiting from before regions keeps its meaning: the whole image.
    func testAnOlderProposalStillApplies() throws {
        let old = try JSONDecoder().decode(FITSFigureRequest.self, from: Data(#"{"scale":3}"#.utf8))
        XCTAssertEqual(old, FITSFigureRequest(scale: 3, region: .image))
    }

    func testOnlyTheFITSViewerOffersAFigureAroundAMark() {
        let model = tab()
        let store = MarkStore(persistence: nil)
        let target = MarkStore.Target(file: URL(fileURLWithPath: "/tmp/ramp.fits"), hdu: 0)
        let fits = FITSMarkCommands(tab: model, editor: MarkEditor(store: store), target: target, say: { _ in })
        let mark = pixelCircle("m1", x: 1, y: 1, radius: 1)
        XCTAssertTrue(MarkMenuItem.items(for: mark, host: fits).contains { $0.command == .exportFigure })
        fits.perform(.exportFigure, on: mark)
        XCTAssertEqual(model.figureRegion, .mark(id: "m1"), "the sheet opens framed on the mark")
    }
}
