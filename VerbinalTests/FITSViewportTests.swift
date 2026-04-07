// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Exhaustive proof that the crosshair stays visible (at the expected screen position)
/// across every zoom method: setZoom, fitToWindow, scroll-wheel zoom, and round-trip transforms.
///
/// All coordinate math lives on FITSViewerModel so these tests exercise the exact
/// same code path that FITSImageView uses at runtime.
@MainActor
final class FITSViewportTests: XCTestCase {

    // MARK: - Helpers

    private let imgSize    = CGSize(width: 500, height: 500)
    private let canvasSize = CGSize(width: 800, height: 600)
    private let canvasCenter = CGPoint(x: 400, y: 300)

    /// Create a minimal FITSViewerModel backed by a synthetic 500×500 HDU (no WCS needed).
    private func makeModel(width: Int = 500, height: Int = 500) -> FITSViewerModel {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "-32", comment: ""))
        header.add(FITSCard(keyword: "NAXIS",  value: "2",   comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "\(width)",  comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "\(height)", comment: ""))
        let hdu  = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 0, wcs: nil)
        let file = FITSFile(url: URL(fileURLWithPath: "/tmp/test.fits"), hdus: [hdu])

        let model = FITSViewerModel()
        model.file = file
        model.selectedHDUIndex = 0
        model.lastCanvasSize = canvasSize
        // Pixels array is not needed for coordinate-transform tests.
        return model
    }

    // MARK: - Test 1: setZoom centers crosshair at canvas center

    func testSetZoomCentersOnCrosshairAtAllZoomLevels() {
        let zoomLevels: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 12.0, 20.0]
        let crosshair = CGPoint(x: 191, y: 195)

        for zoom in zoomLevels {
            let model = makeModel()
            model.crosshairPixel = crosshair

            model.setZoom(zoom)

            let screen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                           "zoom=\(zoom): crosshair.x should be at canvas center x")
            XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                           "zoom=\(zoom): crosshair.y should be at canvas center y")
        }
    }

    // MARK: - Test 2: setZoom works at all crosshair positions

    func testSetZoomWorksAtAllCrosshairPositions() {
        let positions: [CGPoint] = [
            CGPoint(x: 0,   y: 0),
            CGPoint(x: 499, y: 499),
            CGPoint(x: 250, y: 250),
            CGPoint(x: 100, y: 400),
            CGPoint(x: 0,   y: 499),
        ]

        for crosshair in positions {
            let model = makeModel()
            model.crosshairPixel = crosshair

            model.setZoom(8.0)

            let screen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                           "crosshair=(\(crosshair.x),\(crosshair.y)): screen.x should be canvas center")
            XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                           "crosshair=(\(crosshair.x),\(crosshair.y)): screen.y should be canvas center")
        }
    }

    // MARK: - Test 3: setZoom with rotation

    func testSetZoomCentersOnCrosshairWithRotation() {
        let rotations: [Double] = [0, .pi / 4, .pi / 2, .pi, -.pi / 3]
        let crosshair = CGPoint(x: 150, y: 320)

        for rotation in rotations {
            let model = makeModel()
            model.crosshairPixel = crosshair
            model.viewport.rotation = rotation

            model.setZoom(4.0)

            let screen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                           "rotation=\(rotation): crosshair.x should be at canvas center")
            XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                           "rotation=\(rotation): crosshair.y should be at canvas center")
        }
    }

    // MARK: - Test 4: setZoom with flipX

    func testSetZoomCentersOnCrosshairWithFlipX() {
        let crosshair = CGPoint(x: 191, y: 195)
        let model = makeModel()
        model.crosshairPixel = crosshair
        model.viewport.flipX = true

        model.setZoom(4.0)

        let screen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
        XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                       "flipX: crosshair.x should be at canvas center")
        XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                       "flipX: crosshair.y should be at canvas center")
    }

    // MARK: - Test 5: setZoom with rotation + flipX combined

    func testSetZoomCentersOnCrosshairWithRotationAndFlipX() {
        let crosshair = CGPoint(x: 100, y: 300)
        let model = makeModel()
        model.crosshairPixel = crosshair
        model.viewport.rotation = .pi / 6
        model.viewport.flipX = true

        model.setZoom(8.0)

        let screen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
        XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                       "rotation+flipX: crosshair.x should be at canvas center")
        XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                       "rotation+flipX: crosshair.y should be at canvas center")
    }

    // MARK: - Test 6: Scroll zoom keeps crosshair at same screen position

    func testScrollZoomKeepsCrosshairFixed() {
        let crosshair = CGPoint(x: 191, y: 195)
        let model = makeModel()
        model.crosshairPixel = crosshair
        model.viewport.zoom = 1.0
        model.viewport.panX = 0
        model.viewport.panY = 0

        // Capture the crosshair's initial screen position (anchor).
        let anchorScreen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)

        // Simulate 50 consecutive scroll-zoom steps (zoom in at 1.15x per step).
        for step in 1...50 {
            let newZoom = max(0.05, min(20, model.viewport.zoom * 1.15))

            // Anchor image pixel (before zoom changes)
            let anchorImg = model.screenToImage(anchorScreen, imgSize: imgSize, canvasSize: canvasSize)

            // Apply new zoom
            model.viewport.zoom = newZoom

            // Replicate the pan formula from FITSImageView.onScroll
            let rot = model.viewport.rotation
            var dx = (anchorImg.x - imgSize.width  / 2) * newZoom
            let dy = (anchorImg.y - imgSize.height / 2) * newZoom
            if model.viewport.flipX { dx = -dx }
            let cosR = cos(rot)
            let sinR = sin(rot)
            model.viewport.panX = anchorScreen.x - canvasSize.width  / 2 - (dx * cosR - dy * sinR)
            model.viewport.panY = anchorScreen.y - canvasSize.height / 2 - (dx * sinR + dy * cosR)

            // After each step the crosshair must still sit at the same screen position.
            let actual = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(actual.x, anchorScreen.x, accuracy: 0.001,
                           "step \(step), zoom=\(newZoom): crosshair screen.x drifted")
            XCTAssertEqual(actual.y, anchorScreen.y, accuracy: 0.001,
                           "step \(step), zoom=\(newZoom): crosshair screen.y drifted")
        }
    }

    // MARK: - Test 7: Scroll zoom without crosshair keeps cursor position fixed

    func testScrollZoomKeepsCursorFixed() {
        let model = makeModel()
        model.viewport.zoom = 1.0
        model.viewport.panX = 0
        model.viewport.panY = 0

        // Arbitrary cursor position (not canvas center).
        let cursorScreen = CGPoint(x: 150, y: 420)

        for step in 1...50 {
            let newZoom = max(0.05, min(20, model.viewport.zoom * 1.15))

            // Image pixel under cursor (old zoom still active)
            let anchorImg = model.screenToImage(cursorScreen, imgSize: imgSize, canvasSize: canvasSize)

            model.viewport.zoom = newZoom

            let rot = model.viewport.rotation
            var dx = (anchorImg.x - imgSize.width  / 2) * newZoom
            let dy = (anchorImg.y - imgSize.height / 2) * newZoom
            if model.viewport.flipX { dx = -dx }
            let cosR = cos(rot)
            let sinR = sin(rot)
            model.viewport.panX = cursorScreen.x - canvasSize.width  / 2 - (dx * cosR - dy * sinR)
            model.viewport.panY = cursorScreen.y - canvasSize.height / 2 - (dx * sinR + dy * cosR)

            let actual = model.imageToScreen(
                model.screenToImage(cursorScreen, imgSize: imgSize, canvasSize: canvasSize),
                imgSize: imgSize, canvasSize: canvasSize
            )
            XCTAssertEqual(actual.x, cursorScreen.x, accuracy: 0.001,
                           "step \(step), zoom=\(newZoom): cursor screen.x drifted")
            XCTAssertEqual(actual.y, cursorScreen.y, accuracy: 0.001,
                           "step \(step), zoom=\(newZoom): cursor screen.y drifted")
        }
    }

    // MARK: - Test 8: fitToWindow centers crosshair

    func testFitToWindowCentersCrosshair() {
        let positions: [CGPoint] = [
            CGPoint(x: 191, y: 195),
            CGPoint(x: 0,   y: 0),
            CGPoint(x: 499, y: 499),
            CGPoint(x: 250, y: 250),
        ]

        for crosshair in positions {
            let model = makeModel()
            model.crosshairPixel = crosshair

            model.fitToWindow(canvasSize: canvasSize)

            let screen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                           "fitToWindow, crosshair=(\(crosshair.x),\(crosshair.y)): screen.x should be canvas center")
            XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                           "fitToWindow, crosshair=(\(crosshair.x),\(crosshair.y)): screen.y should be canvas center")
        }
    }

    // MARK: - Test 9: screenToImage ↔ imageToScreen round-trip (no transforms)

    func testRoundTripNoTransform() {
        // 20 deterministic image points spread across the 500×500 image.
        let imgPoints: [CGPoint] = stride(from: 0, to: 20, by: 1).map { i in
            CGPoint(x: Double(i) * 24.7 + 3.1, y: Double(i) * 18.3 + 7.9)
        }

        let model = makeModel()
        model.viewport.zoom   = 3.0
        model.viewport.panX   = 42.5
        model.viewport.panY   = -18.0
        model.viewport.rotation = 0
        model.viewport.flipX  = false

        for imgPt in imgPoints {
            let screen = model.imageToScreen(imgPt, imgSize: imgSize, canvasSize: canvasSize)
            let back   = model.screenToImage(screen, imgSize: imgSize, canvasSize: canvasSize)

            XCTAssertEqual(back.x, imgPt.x, accuracy: 0.0001,
                           "Round-trip x failed for (\(imgPt.x), \(imgPt.y))")
            XCTAssertEqual(back.y, imgPt.y, accuracy: 0.0001,
                           "Round-trip y failed for (\(imgPt.x), \(imgPt.y))")
        }
    }

    // MARK: - Test 10: screenToImage ↔ imageToScreen round-trip with rotation + flipX

    func testRoundTripWithRotationAndFlipX() {
        let imgPoints: [CGPoint] = stride(from: 0, to: 20, by: 1).map { i in
            CGPoint(x: Double(i) * 24.7 + 3.1, y: Double(i) * 18.3 + 7.9)
        }

        let model = makeModel()
        model.viewport.zoom     = 5.0
        model.viewport.panX     = -30.0
        model.viewport.panY     = 55.0
        model.viewport.rotation = .pi / 3
        model.viewport.flipX    = true

        for imgPt in imgPoints {
            let screen = model.imageToScreen(imgPt, imgSize: imgSize, canvasSize: canvasSize)
            let back   = model.screenToImage(screen, imgSize: imgSize, canvasSize: canvasSize)

            XCTAssertEqual(back.x, imgPt.x, accuracy: 0.0001,
                           "Rotation+flip round-trip x failed for (\(imgPt.x), \(imgPt.y))")
            XCTAssertEqual(back.y, imgPt.y, accuracy: 0.0001,
                           "Rotation+flip round-trip y failed for (\(imgPt.x), \(imgPt.y))")
        }
    }

    // MARK: - Bonus: setZoom clamps below-minimum to 0.05

    func testSetZoomClampsBelowMinimum() {
        let model = makeModel()
        model.setZoom(0.001)
        XCTAssertEqual(model.viewport.zoom, 0.05, accuracy: 0.0001,
                       "setZoom should clamp to minimum 0.05")
    }

    // MARK: - Bonus: setZoom clamps above-maximum to 20

    func testSetZoomClampsAboveMaximum() {
        let model = makeModel()
        model.setZoom(999)
        XCTAssertEqual(model.viewport.zoom, 20.0, accuracy: 0.0001,
                       "setZoom should clamp to maximum 20.0")
    }

    // MARK: - Bonus: Image center always maps to canvas center when pan=0

    func testImageCenterMapsToCanvasCenterWhenPanIsZero() {
        let center = CGPoint(x: imgSize.width / 2, y: imgSize.height / 2)

        for zoom in [0.5, 1.0, 2.0, 8.0] as [Double] {
            let model = makeModel()
            model.viewport.zoom   = zoom
            model.viewport.panX   = 0
            model.viewport.panY   = 0
            model.viewport.rotation = 0

            let screen = model.imageToScreen(center, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(screen.x, canvasCenter.x, accuracy: 0.001,
                           "zoom=\(zoom): image center should map to canvas center x when pan=0")
            XCTAssertEqual(screen.y, canvasCenter.y, accuracy: 0.001,
                           "zoom=\(zoom): image center should map to canvas center y when pan=0")
        }
    }

    // MARK: - Bonus: Scroll-zoom accumulation with rotation + flipX, no drift

    func testScrollZoomNoDriftWithRotationAndFlipX() {
        let crosshair = CGPoint(x: 80, y: 390)
        let model = makeModel()
        model.crosshairPixel    = crosshair
        model.viewport.zoom     = 1.0
        model.viewport.panX     = 0
        model.viewport.panY     = 0
        model.viewport.rotation = .pi / 7
        model.viewport.flipX    = true

        let anchorScreen = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)

        for step in 1...50 {
            let newZoom   = max(0.05, min(20, model.viewport.zoom * 1.15))
            let anchorImg = model.screenToImage(anchorScreen, imgSize: imgSize, canvasSize: canvasSize)

            model.viewport.zoom = newZoom

            let rot = model.viewport.rotation
            var dx = (anchorImg.x - imgSize.width  / 2) * newZoom
            let dy = (anchorImg.y - imgSize.height / 2) * newZoom
            if model.viewport.flipX { dx = -dx }
            let cosR = cos(rot)
            let sinR = sin(rot)
            model.viewport.panX = anchorScreen.x - canvasSize.width  / 2 - (dx * cosR - dy * sinR)
            model.viewport.panY = anchorScreen.y - canvasSize.height / 2 - (dx * sinR + dy * cosR)

            let actual = model.imageToScreen(crosshair, imgSize: imgSize, canvasSize: canvasSize)
            XCTAssertEqual(actual.x, anchorScreen.x, accuracy: 0.001,
                           "rotation+flipX, step \(step): crosshair screen.x drifted")
            XCTAssertEqual(actual.y, anchorScreen.y, accuracy: 0.001,
                           "rotation+flipX, step \(step): crosshair screen.y drifted")
        }
    }
}
