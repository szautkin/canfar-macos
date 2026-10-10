// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import CoreGraphics
import os.log
#if os(macOS)
import AppKit
#endif
import VerbinalKit

/// The image's geometry on screen: fitting, rotating and mapping it.
extension FITSViewerModel {
    // MARK: - Geometry Utilities

    /// Convert display Y (origin top-left) to FITS Y (origin bottom-left).
    static func displayToFITSY(_ displayY: Double, naxis2: Int) -> Double {
        Double(naxis2 - 1) - displayY
    }

    /// 0-based FITS array indices of the pixel drawn under a display-space
    /// point. `pixels` is stored in file order (row 0 first) and the
    /// renderer draws buffer row `naxis2 - 1 - displayRow`, so the row
    /// flips. This is the convention `probe_fits_pixel` takes.
    static func arrayPixel(atDisplay point: CGPoint, naxis2: Int) -> (x: Int, y: Int) {
        FITSDisplayGrid(width: 0, height: naxis2).index(ofDisplay: point)
    }

    /// Readout text for one sample: 4 significant digits, "NaN" for blanks.
    static func formatPixelValue(_ value: Float) -> String {
        value.isFinite ? String(format: "%.4g", value) : "NaN"
    }

    /// Raw sample at 0-based FITS array indices; nil outside the image.
    func sample(x: Int, y: Int) -> Float? {
        guard let hdu = selectedHDU,
              x >= 0, y >= 0, x < hdu.header.naxis1, y < hdu.header.naxis2 else { return nil }
        let index = y * hdu.header.naxis1 + x
        return pixels.indices.contains(index) ? pixels[index] : nil
    }

    /// Readout text for the pixel drawn under a display-space point.
    func pixelValueText(atDisplay point: CGPoint) -> String? {
        guard let hdu = selectedHDU else { return nil }
        let pixel = Self.arrayPixel(atDisplay: point, naxis2: hdu.header.naxis2)
        return sample(x: pixel.x, y: pixel.y).map(Self.formatPixelValue)
    }

    /// Apply a linked crosshair from the shared store (marks crosshair as linked).
    /// FITSTabHostModel should call this instead of setting crosshairPixel directly.
    func applyLinkedCrosshair(pixel: CGPoint, ra: Double, dec: Double) {
        crosshairPixel = pixel
        crosshairRA = Sexagesimal.readoutHMS(degrees: ra)
        crosshairDec = Sexagesimal.readoutDMS(degrees: dec)
        isLinkedCrosshair = true
    }

    /// Place crosshair at image pixel (0-based, display-space Y already flipped).
    func placeCrosshair(at point: CGPoint) {
        guard let hdu = selectedHDU else {
            Self.logger.warning("placeCrosshair: no selected HDU")
            return
        }
        guard point.x >= 0, point.y >= 0,
              point.x < Double(hdu.header.naxis1),
              point.y < Double(hdu.header.naxis2) else {
            Self.logger.warning("placeCrosshair: out of bounds (\(point.x), \(point.y)) for \(hdu.header.naxis1)×\(hdu.header.naxis2)")
            return
        }
        Self.logger.debug("placeCrosshair at (\(point.x), \(point.y))")
        crosshairPixel = point
        isLinkedCrosshair = false

        if let text = pixelValueText(atDisplay: point) {
            crosshairValue = text
        }

        // Clear out-of-bounds state when user places a new crosshair
        crosshairOutOfBounds = false

        if let wcs {
            let fitsY = Self.displayToFITSY(point.y, naxis2: hdu.header.naxis2)
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            crosshairRA = Sexagesimal.readoutHMS(degrees: ra)
            crosshairDec = Sexagesimal.readoutDMS(degrees: dec)
            crosshairRADeg = ra
            crosshairDecDeg = dec
            Self.logger.info("Crosshair WCS: RA=\(self.crosshairRA) Dec=\(self.crosshairDec) val=\(self.crosshairValue)")
            onCrosshairPlaced?(ra, dec)
        } else {
            Self.logger.info("placeCrosshair: no WCS — using pixel-only sync")
            crosshairRA = String(format: "px %.0f", point.x)
            crosshairDec = String(format: "py %.0f", point.y)
            crosshairRADeg = nil
            crosshairDecDeg = nil
            // Fire pixel-only sync callback for images without WCS
            onPixelCrosshairPlaced?(point)
        }
    }

    /// Update cursor readout (no permanent crosshair).
    func updateCursorInfo(at point: CGPoint) {
        guard let hdu = selectedHDU else { return }
        if let text = pixelValueText(atDisplay: point) {
            cursorPixelValue = text
        }

        if let wcs {
            let fitsY = Self.displayToFITSY(point.y, naxis2: hdu.header.naxis2)
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            cursorRA = Sexagesimal.readoutHMS(degrees: ra)
            cursorDec = Sexagesimal.readoutDMS(degrees: dec)
        }
    }
}
