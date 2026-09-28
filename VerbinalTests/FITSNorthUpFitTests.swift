// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import XCTest
import VerbinalKit
@testable import Verbinal

/// North Up turns the image; a view that showed all of it still does
/// (plan 15 V4, QA M6: on the JADES frame, north at 61.47°, the corners
/// were cut off).
@MainActor
final class FITSNorthUpFitTests: XCTestCase {

    private let canvas = CGSize(width: 800, height: 600)

    /// A 2000×1000 image whose north is 61.47° from up.
    private func model() -> FITSViewerModel {
        let model = FITSViewerModel()
        let theta = 61.47 * Double.pi / 180, scale = 0.00001
        FITSTestFixtures.loadRamp(into: model, width: 2000, height: 1000, wcsCards: [
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
            ("CRVAL1", "53.16"), ("CRVAL2", "-27.78"), ("CRPIX1", "1000"), ("CRPIX2", "500"),
            ("CD1_1", "\(-scale * cos(theta))"), ("CD1_2", "\(scale * sin(theta))"),
            ("CD2_1", "\(scale * sin(theta))"), ("CD2_2", "\(scale * cos(theta))"),
        ])
        model.lastCanvasSize = canvas
        return model
    }

    private func cornersOnCanvas(_ model: FITSViewerModel) throws -> Bool {
        let v = model.viewport
        let transform = ViewportTransform(zoom: v.zoom, rotation: v.rotation, flipX: v.flipX, panX: v.panX, panY: v.panY,
                                          imageSize: CGSize(width: 2000, height: 1000), canvasSize: canvas)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 2000, y: 0), CGPoint(x: 0, y: 1000), CGPoint(x: 2000, y: 1000)]
        return corners.map(transform.imageToScreen).allSatisfy {
            $0.x >= -0.5 && $0.x <= canvas.width + 0.5 && $0.y >= -0.5 && $0.y <= canvas.height + 0.5
        }
    }

    func testAFittedViewStaysWholeWhenTurnedNorthUp() throws {
        let model = model()
        model.fitToWindow(canvasSize: canvas)
        XCTAssertTrue(try cornersOnCanvas(model))

        model.applyNorthUp()

        XCTAssertNotEqual(model.viewport.rotation, 0, accuracy: 0.1)
        XCTAssertTrue(try cornersOnCanvas(model), "every corner still on the canvas")
        XCTAssertTrue(model.isFitted(canvasSize: canvas))
    }

    func testAZoomedInViewKeepsItsZoom() throws {
        let model = model()
        model.fitToWindow(canvasSize: canvas)
        model.viewport.zoom *= 3
        let zoom = model.viewport.zoom

        model.applyNorthUp()

        XCTAssertEqual(model.viewport.zoom, zoom, "the person's zoom is theirs")
    }

    func testTheTurnedBoxIsWhatIsFitted() {
        let size = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(ViewportTransform.fitZoom(imageSize: size, canvasSize: canvas), 0.4)
        let turned = ViewportTransform.fitZoom(imageSize: size, canvasSize: canvas, rotation: .pi / 2)
        XCTAssertEqual(turned ?? 0, 0.3, accuracy: 1e-9, "a quarter turn fits 1000 wide by 2000 high")
    }
}
