// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Transform parameters for overlaying image B on top of image A during blink comparison.
///
/// The overlay image is rendered into image A's canvas coordinate space using a
/// CompositeTransform (scale → rotate → translate, centered on image midpoint).
/// Matching Windows BlinkAligner.BlinkTransform.
struct BlinkTransform: Sendable {
    /// Rotation in radians (North-up, matching image A's sky orientation).
    let rotation: Double
    /// Horizontal scale factor for image B (negative when parity differs from A).
    let scaleX: Double
    /// Vertical scale factor for image B.
    let scaleY: Double
    /// Pan offset X in canvas coordinates, centering the reference sky position.
    let translateX: Double
    /// Pan offset Y in canvas coordinates, centering the reference sky position.
    let translateY: Double
}

/// Pure math for aligning two FITS images for blink comparison.
///
/// Computes `BlinkTransform` so that overlay image B appears at the same sky
/// position and angular scale as image A's current viewport. Matches Windows
/// `BlinkAligner.ComputeAlignedTransform()`.
enum BlinkAligner {

    // MARK: - Main Entry Point

    /// Compute the transform to overlay image B aligned to image A's current view.
    ///
    /// - Parameters:
    ///   - wcsA: WCS of image A (the primary/reference image).
    ///   - wcsB: WCS of image B (the overlay image).
    ///   - rotationA: Image A's current viewport rotation in radians.
    ///   - zoomA: Image A's current viewport zoom (px/px, not angular).
    ///   - referenceRA: Reference sky position RA in degrees (use crosshair or WCS center).
    ///   - referenceDec: Reference sky position Dec in degrees.
    ///   - imageWidthB: Pixel width of image B.
    ///   - imageHeightB: Pixel height of image B.
    ///   - displayWidthA: Rendered display width of image A on canvas (pixels).
    ///   - displayHeightA: Rendered display height of image A on canvas (pixels).
    ///   - canvasWidth: Canvas width.
    ///   - canvasHeight: Canvas height.
    /// - Returns: Transform for the overlay, or nil if WCS is degenerate.
    static func computeAlignedTransform(
        wcsA: FITSWCSTransform,
        wcsB: FITSWCSTransform,
        rotationA: Double,
        zoomA: Double,
        referenceRA: Double,
        referenceDec: Double,
        imageWidthB: Int,
        imageHeightB: Int,
        displayWidthA: Double,
        displayHeightA: Double,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> BlinkTransform? {
        // 1. Scale: match angular extent of A at its current zoom.
        //    If B has larger pixels (coarser), it needs less zoom.
        let matchedZoom = computeMatchedZoom(
            zoomA: zoomA,
            pixelScaleA: wcsA.pixelScaleArcsec,
            pixelScaleB: wcsB.pixelScaleArcsec
        )

        // 2. Rotation: apply North-up relative to A's current sky orientation.
        //    rotB = rotA + (northAngleA - northAngleB) converted to radians.
        //    This ensures both images present the same sky orientation.
        let rotationB = rotationA + (wcsA.northAngle - wcsB.northAngle) * .pi / 180.0

        // 3. Parity: if B's parity differs from A's (accounting for A's current flip state),
        //    negate scaleX to mirror the overlay horizontally.
        let aIsFlipped = wcsA.hasParityFlip
        let bIsFlipped = wcsB.hasParityFlip
        let scaleXB = (bIsFlipped != aIsFlipped) ? -matchedZoom : matchedZoom

        // 4. Translate: find where the reference RA/Dec lands in image B's pixel space,
        //    then compute the pan needed to center it on the canvas.
        //
        //    The overlay image is forced to fill image A's display bounds (Stretch=Fill),
        //    so we work in A's display coordinate space throughout.
        guard let pixelB = wcsB.worldToPixel(ra: referenceRA, dec: referenceDec) else {
            // Reference point not in image B — use zero translate (best-effort).
            return BlinkTransform(
                rotation: rotationB,
                scaleX: scaleXB,
                scaleY: matchedZoom,
                translateX: 0,
                translateY: 0
            )
        }

        // Map B's FITS pixel (0-based) to display coordinates in A's display space.
        // displayY flips FITS (bottom-origin) to screen (top-origin).
        let displayX = (pixelB.x / Double(imageWidthB)) * displayWidthA
        let displayY = (Double(imageHeightB - 1) - pixelB.y) / Double(imageHeightB) * displayHeightA

        // Compute translate to center that display pixel on the canvas.
        let (txB, tyB) = computeCenterTranslate(
            localX: displayX,
            localY: displayY,
            scaleX: scaleXB,
            scaleY: matchedZoom,
            rotation: rotationB,
            imgW: displayWidthA,
            imgH: displayHeightA,
            canvasW: canvasWidth,
            canvasH: canvasHeight
        )

        return BlinkTransform(
            rotation: rotationB,
            scaleX: scaleXB,
            scaleY: matchedZoom,
            translateX: txB,
            translateY: tyB
        )
    }

    // MARK: - Viewport Math (matches Windows ViewportMath)

    /// Compute zoom for image B that matches the angular extent of image A.
    ///
    /// If B has coarser pixels (larger arcsec/px), it needs proportionally less zoom
    /// to cover the same angular area on screen.
    static func computeMatchedZoom(
        zoomA: Double,
        pixelScaleA: Double,
        pixelScaleB: Double
    ) -> Double {
        guard pixelScaleB > 0 else { return zoomA }
        return zoomA * (pixelScaleA / pixelScaleB)
    }

    /// Compute the translate needed to center a given local coordinate on the canvas.
    ///
    /// Transform order (CompositeTransform with center origin):
    ///   center → scale → rotate → translate → uncenter
    /// We want the local point to map to canvas center (canvasW/2, canvasH/2).
    ///
    /// Matches Windows `ViewportMath.ComputeCenterTranslate()`.
    static func computeCenterTranslate(
        localX: Double, localY: Double,
        scaleX: Double, scaleY: Double,
        rotation: Double,
        imgW: Double, imgH: Double,
        canvasW: Double, canvasH: Double
    ) -> (translateX: Double, translateY: Double) {
        let cx = imgW / 2
        let cy = imgH / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)

        // Scale relative to image center, then rotate
        let dx = (localX - cx) * scaleX
        let dy = (localY - cy) * scaleY
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR

        // Image offset (centering image on canvas when translate=0)
        let imgOffsetX = (canvasW - imgW) / 2
        let imgOffsetY = (canvasH - imgH) / 2

        // Solve: canvasW/2 = imgOffsetX + rx + cx + translateX
        let translateX = canvasW / 2 - imgOffsetX - rx - cx
        let translateY = canvasH / 2 - imgOffsetY - ry - cy
        return (translateX, translateY)
    }
}
