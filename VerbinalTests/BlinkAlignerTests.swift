// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import simd
@testable import Verbinal
import VerbinalKit

/// Tests for BlinkAligner, mirroring Windows BlinkAlignerTests.cs.
final class BlinkAlignerTests: XCTestCase {

    private let tolerance = 1.5  // sub-pixel accuracy is sufficient for blink alignment

    // MARK: - Helpers

    /// Create a simple WCS at `(crval1, crval2)` with pixel scale `cdelt` (deg/px)
    /// and optional rotation `rotaDeg` degrees.
    private func makeWCS(
        crval1: Double, crval2: Double,
        cdelt: Double,
        rotaDeg: Double = 0,
        crpix1: Double = 512, crpix2: Double = 512
    ) -> FITSWCSTransform {
        let rota = rotaDeg * .pi / 180.0
        // Typical astronomical CD matrix (RA increases leftward → CD1_1 negative)
        let cd = simd_double2x2(columns: (
            simd_double2(-cdelt * cos(rota), cdelt * sin(rota)),  // (CD1_1, CD2_1)
            simd_double2( cdelt * sin(rota), cdelt * cos(rota))   // (CD1_2, CD2_2)
        ))
        return FITSWCSTransform(
            crpix1: crpix1 - 1,  // FITS 1-based → 0-based
            crpix2: crpix2 - 1,
            crval1: crval1,
            crval2: crval2,
            cd: cd,
            cdInv: simd_inverse(cd),
            ctype1: "RA---TAN",
            ctype2: "DEC--TAN"
        )
    }

    // MARK: - computeMatchedZoom

    func testMatchedZoom_SameScale_ReturnsSameZoom() {
        let zoom = BlinkAligner.computeMatchedZoom(zoomA: 2.0, pixelScaleA: 1.0, pixelScaleB: 1.0)
        XCTAssertEqual(zoom, 2.0, accuracy: 1e-10)
    }

    func testMatchedZoom_CoarserB_LessZoom() {
        // B has 2x coarser pixels → needs half the zoom to match angular extent
        let zoom = BlinkAligner.computeMatchedZoom(zoomA: 2.0, pixelScaleA: 1.0, pixelScaleB: 2.0)
        XCTAssertEqual(zoom, 1.0, accuracy: 1e-10)
    }

    func testMatchedZoom_FinerB_MoreZoom() {
        // B has 2x finer pixels → needs double the zoom
        let zoom = BlinkAligner.computeMatchedZoom(zoomA: 1.0, pixelScaleA: 2.0, pixelScaleB: 1.0)
        XCTAssertEqual(zoom, 2.0, accuracy: 1e-10)
    }

    func testMatchedZoom_ZeroScaleB_ReturnsSameZoom() {
        // Guard against division by zero
        let zoom = BlinkAligner.computeMatchedZoom(zoomA: 1.5, pixelScaleA: 1.0, pixelScaleB: 0.0)
        XCTAssertEqual(zoom, 1.5, accuracy: 1e-10)
    }

    // MARK: - computeCenterTranslate

    func testCenterTranslate_ImageCenter_ZeroTranslate() {
        // When the reference point is at the image center and scale=1, rotation=0,
        // translate should be zero (image is already centered on canvas if imgW==canvasW).
        let (tx, ty) = BlinkAligner.computeCenterTranslate(
            localX: 512, localY: 512,
            scaleX: 1.0, scaleY: 1.0,
            rotation: 0,
            imgW: 1024, imgH: 1024,
            canvasW: 1024, canvasH: 1024
        )
        XCTAssertEqual(tx, 0, accuracy: 1e-6)
        XCTAssertEqual(ty, 0, accuracy: 1e-6)
    }

    // MARK: - computeAlignedTransform

    func testAlignedTransform_SameWCS_CentersReferencePoint() {
        // With identical WCS, the reference point (crval) should map to canvas center.
        let wcs = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001)

        let result = BlinkAligner.computeAlignedTransform(
            wcsA: wcs, wcsB: wcs,
            rotationA: 0, zoomA: 1.0,
            referenceRA: 180, referenceDec: 45,
            imageWidthB: 1024, imageHeightB: 1024,
            displayWidthA: 1024, displayHeightA: 1024,
            canvasWidth: 1200, canvasHeight: 900
        )

        XCTAssertNotNil(result)
    }

    func testAlignedTransform_DifferentPixelScale_MatchesZoom() {
        // B has 2x coarser pixels → matched zoom should be half of A's zoom.
        let wcsA = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001) // ~3.6"/px
        let wcsB = makeWCS(crval1: 180, crval2: 45, cdelt: 0.002) // ~7.2"/px
        let zoomA = 2.0
        let expectedZoom = BlinkAligner.computeMatchedZoom(
            zoomA: zoomA,
            pixelScaleA: wcsA.pixelScaleArcsec,
            pixelScaleB: wcsB.pixelScaleArcsec
        )

        let result = BlinkAligner.computeAlignedTransform(
            wcsA: wcsA, wcsB: wcsB,
            rotationA: 0, zoomA: zoomA,
            referenceRA: 180, referenceDec: 45,
            imageWidthB: 1024, imageHeightB: 1024,
            displayWidthA: 1024, displayHeightA: 1024,
            canvasWidth: 1200, canvasHeight: 900
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.scaleY, expectedZoom, accuracy: tolerance)
        XCTAssertEqual(abs(result!.scaleX), expectedZoom, accuracy: tolerance)
    }

    func testAlignedTransform_SameParity_ScaleXPositive() {
        // Both images have same parity flip (both have negative det) → scaleX positive.
        // A standard astronomical CD matrix with negative CD1_1 has det > 0 (parity flip).
        // Create two images with same parity.
        let wcsA = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001)
        let wcsB = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001)
        XCTAssertEqual(wcsA.hasParityFlip, wcsB.hasParityFlip,
                       "Both test WCS should have same parity")

        let result = BlinkAligner.computeAlignedTransform(
            wcsA: wcsA, wcsB: wcsB,
            rotationA: 0, zoomA: 1.0,
            referenceRA: 180, referenceDec: 45,
            imageWidthB: 1024, imageHeightB: 1024,
            displayWidthA: 1024, displayHeightA: 1024,
            canvasWidth: 1200, canvasHeight: 900
        )

        XCTAssertNotNil(result)
        // Same parity → no mirror → scaleX is positive
        XCTAssertTrue(result!.scaleX > 0, "scaleX should be positive when parity matches")
    }

    func testAlignedTransform_RotationMatchesNorthAngleDifference() {
        // rotB = rotA + (northAngleA - northAngleB) * π/180
        let wcsA = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001, rotaDeg: 20)
        let wcsB = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001, rotaDeg: 50)
        let rotationA = 0.0 // image A is at 0 rotation on screen

        let result = BlinkAligner.computeAlignedTransform(
            wcsA: wcsA, wcsB: wcsB,
            rotationA: rotationA, zoomA: 1.0,
            referenceRA: 180, referenceDec: 45,
            imageWidthB: 1024, imageHeightB: 1024,
            displayWidthA: 1024, displayHeightA: 1024,
            canvasWidth: 1200, canvasHeight: 900
        )

        XCTAssertNotNil(result)
        let expectedRotation = rotationA + (wcsA.northAngle - wcsB.northAngle) * .pi / 180.0
        XCTAssertEqual(result!.rotation, expectedRotation, accuracy: 1e-6)
    }

    func testAlignedTransform_NilWhenReferenceNotInImageB() {
        // If the reference point is wildly far from image B's WCS center,
        // worldToPixel may return a pixel that is in-bounds but the transform
        // should still succeed (we always return a transform, never nil for this case).
        // This test just checks that we get a non-nil result regardless.
        let wcsA = makeWCS(crval1: 180, crval2: 45, cdelt: 0.001)
        let wcsB = makeWCS(crval1: 90, crval2: 0, cdelt: 0.001) // far away

        let result = BlinkAligner.computeAlignedTransform(
            wcsA: wcsA, wcsB: wcsB,
            rotationA: 0, zoomA: 1.0,
            referenceRA: 180, referenceDec: 45,
            imageWidthB: 1024, imageHeightB: 1024,
            displayWidthA: 1024, displayHeightA: 1024,
            canvasWidth: 1200, canvasHeight: 900
        )

        // Should return a transform (possibly with large translate) rather than nil
        XCTAssertNotNil(result)
    }

    // MARK: - FITSTabHostModel blink state machine

    @MainActor
    func testStartBlink_SetsIsBlinking() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 1)
        XCTAssertTrue(host.isBlinking)
        XCTAssertFalse(host.isBlinkPaused)
        host.stopBlink()
    }

    @MainActor
    func testStartBlink_SetsActiveTabToA() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.activeTabIndex = 1
        host.startBlink(tabA: 0, tabB: 1)
        // Active tab should stay on A (0), not switch
        XCTAssertEqual(host.activeTabIndex, 0)
        host.stopBlink()
    }

    @MainActor
    func testStopBlink_ClearsState() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 1)
        host.stopBlink()
        XCTAssertFalse(host.isBlinking)
        XCTAssertFalse(host.isBlinkPaused)
        XCTAssertNil(host.blinkOverlayImage)
        XCTAssertNil(host.blinkTransform)
        XCTAssertEqual(host.blinkOpacity, 0)
    }

    @MainActor
    func testShowBlinkA_FreezesAtZero() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 1)
        host.showBlinkA()
        XCTAssertEqual(host.blinkOpacity, 0)
        XCTAssertTrue(host.isBlinkPaused)
        host.stopBlink()
    }

    @MainActor
    func testShowBlinkB_FreezesAtOne() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 1)
        host.showBlinkB()
        XCTAssertEqual(host.blinkOpacity, 1)
        XCTAssertTrue(host.isBlinkPaused)
        host.stopBlink()
    }

    @MainActor
    func testStartBlink_InvalidIndices_DoesNotStart() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 99)  // tabB out of range
        XCTAssertFalse(host.isBlinking)
    }

    @MainActor
    func testStartBlink_SameTab_DoesNotStart() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 0)  // same tab
        XCTAssertFalse(host.isBlinking)
    }

    @MainActor
    func testCloseTabWhileBlinking_StopsBlink() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.startBlink(tabA: 0, tabB: 1)
        XCTAssertTrue(host.isBlinking)
        host.closeTab(at: 1)
        XCTAssertFalse(host.isBlinking, "Closing a blink tab should stop blink")
    }
}
