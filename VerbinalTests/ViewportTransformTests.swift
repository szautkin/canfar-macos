// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Pure-math tests for ``ViewportTransform``. Pinned because crosshair /
/// WCS coordinates depend on this round-tripping correctly under every
/// combination of zoom, flip, rotation, and pan; a regression silently
/// gives wrong sky coordinates rather than crashing.
final class ViewportTransformTests: XCTestCase {

    private let imageSize = CGSize(width: 1024, height: 1024)
    private let canvasSize = CGSize(width: 800, height: 600)

    private func make(zoom: Double = 1.0,
                      rotation: Double = 0.0,
                      flipX: Bool = false,
                      panX: Double = 0.0,
                      panY: Double = 0.0) -> ViewportTransform {
        ViewportTransform(
            zoom: zoom, rotation: rotation, flipX: flipX,
            panX: panX, panY: panY,
            imageSize: imageSize, canvasSize: canvasSize
        )
    }

    private func assertClose(_ a: CGPoint, _ b: CGPoint,
                             accuracy: Double = 1e-9,
                             file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Identity-like cases

    func testImageCenterMapsToCanvasCenterAtZoom1() {
        let t = make()
        let center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        let screen = t.imageToScreen(center)
        assertClose(screen, CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    func testCanvasCenterMapsBackToImageCenter() {
        let t = make()
        let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let img = t.screenToImage(canvasCenter)
        assertClose(img, CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
    }

    // MARK: - Round-trip

    func testRoundTripIsIdentityForArbitraryViewport() {
        // Random-ish but reproducible viewport state covering all axes.
        let t = make(zoom: 2.5, rotation: .pi / 6, flipX: true, panX: 12.5, panY: -7.0)
        let original = CGPoint(x: 300.0, y: 700.0)
        let screen = t.imageToScreen(original)
        let back = t.screenToImage(screen)
        assertClose(back, original, accuracy: 1e-6)
    }

    func testRoundTripWithFlipNoRotation() {
        let t = make(zoom: 1.5, flipX: true, panX: 50, panY: -20)
        let original = CGPoint(x: 100, y: 200)
        let back = t.screenToImage(t.imageToScreen(original))
        assertClose(back, original, accuracy: 1e-9)
    }

    func testRoundTripWithRotationNoFlip() {
        let t = make(zoom: 1.0, rotation: .pi / 2, panX: 0, panY: 0)
        let original = CGPoint(x: 1024, y: 0)  // top-right corner
        let back = t.screenToImage(t.imageToScreen(original))
        assertClose(back, original, accuracy: 1e-9)
    }

    // MARK: - Pan-to-center

    func testPanToCenterPlacesPixelAtCanvasCenter() {
        let t = make(zoom: 2.0)
        let target = CGPoint(x: 700, y: 300)
        let pan = t.panToCenter(target)
        let panned = ViewportTransform(
            zoom: 2.0, rotation: 0, flipX: false,
            panX: pan.panX, panY: pan.panY,
            imageSize: imageSize, canvasSize: canvasSize
        )
        let screen = panned.imageToScreen(target)
        let canvasCenter = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        assertClose(screen, canvasCenter, accuracy: 1e-9)
    }

    func testPanToCenterIgnoresExistingPan() {
        // The returned (panX, panY) replaces, not adds — so calling it on a
        // viewport that's already panned still produces the correct centre.
        let preexisting = make(zoom: 1.0, panX: 999, panY: -500)
        let target = CGPoint(x: 200, y: 300)
        let pan = preexisting.panToCenter(target)
        let result = ViewportTransform(
            zoom: 1.0, rotation: 0, flipX: false,
            panX: pan.panX, panY: pan.panY,
            imageSize: imageSize, canvasSize: canvasSize
        )
        let screen = result.imageToScreen(target)
        assertClose(screen, CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    // MARK: - Fit zoom

    func testFitZoomChoosesMinDimension() {
        // 1024 image into 800×600 canvas → bounded by height.
        let z = try? XCTUnwrap(
            ViewportTransform.fitZoom(imageSize: imageSize, canvasSize: canvasSize)
        )
        XCTAssertEqual(z ?? 0, 600.0 / 1024.0, accuracy: 1e-9)
    }

    func testFitZoomReturnsNilForZeroDimension() {
        XCTAssertNil(ViewportTransform.fitZoom(imageSize: .zero, canvasSize: canvasSize))
        XCTAssertNil(ViewportTransform.fitZoom(
            imageSize: CGSize(width: 0, height: 100),
            canvasSize: canvasSize
        ))
    }
}
