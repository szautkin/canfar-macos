// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import CoreGraphics
#if os(macOS)
import AppKit
#endif

/// Per-file FITS viewer state.
@Observable
@MainActor
final class FITSViewerModel: Identifiable {
    let id = UUID()
    var file: FITSFile?
    var selectedHDUIndex = 0
    var renderParams = FITSRenderParams()
    var viewport = FITSViewport()
    var renderedImage: CGImage?
    var pixels: [Float] = []

    // Crosshair
    var crosshairPixel: CGPoint?
    var crosshairRA: String = ""
    var crosshairDec: String = ""
    var crosshairValue: String = ""

    // Mouse readout
    var cursorRA: String = ""
    var cursorDec: String = ""
    var cursorPixelValue: String = ""

    // State
    var isLoading = false
    var loadError: String?
    var fileURL: URL?

    var selectedHDU: FITSHDUnit? {
        guard let file, selectedHDUIndex < file.hdus.count else { return nil }
        return file.hdus[selectedHDUIndex]
    }

    var imageHDUs: [FITSHDUnit] {
        file?.hdus.filter(\.isImage) ?? []
    }

    var wcs: FITSWCSTransform? { selectedHDU?.wcs }

    // MARK: - File Operations

    func open(url: URL) async {
        isLoading = true
        loadError = nil
        fileURL = url

        do {
            let fitsFile = try FITSParser.parse(url: url)
            guard let imageHDU = fitsFile.firstImageHDU else {
                throw FITSError.noImageHDU
            }

            file = fitsFile
            selectedHDUIndex = imageHDU.id

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            pixels = try FITSParser.extractPixels(from: data, hdu: imageHDU)

            let cuts = FITSParser.autoCut(pixels: pixels)
            renderParams.minCut = cuts.min
            renderParams.maxCut = cuts.max

            renderImage()
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    func selectHDU(_ index: Int) async {
        guard let file, index < file.hdus.count, file.hdus[index].isImage else { return }
        selectedHDUIndex = index

        guard let url = fileURL else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            pixels = try FITSParser.extractPixels(from: data, hdu: file.hdus[index])
            let cuts = FITSParser.autoCut(pixels: pixels)
            renderParams.minCut = cuts.min
            renderParams.maxCut = cuts.max
            renderImage()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Rendering

    func renderImage() {
        guard let hdu = selectedHDU, !pixels.isEmpty else { return }
        renderedImage = FITSRenderEngine.render(
            pixels: pixels,
            width: hdu.header.naxis1,
            height: hdu.header.naxis2,
            params: renderParams
        )
    }

    // MARK: - Crosshair

    /// Callback for linked crosshair — set by tab host.
    var onCrosshairPlaced: ((Double, Double) -> Void)?
    /// Callback for linked zoom — set by tab host.
    var onZoomChanged: (() -> Void)?
    /// Callback for "Search at Position" context menu.
    var onSearchAtPosition: ((Double, Double) -> Void)?

    /// Place crosshair at image pixel (0-based, display-space Y already flipped).
    func placeCrosshair(at point: CGPoint) {
        guard let hdu = selectedHDU else { return }
        crosshairPixel = point

        let pixelIdx = Int(point.y) * hdu.header.naxis1 + Int(point.x)
        if pixelIdx >= 0 && pixelIdx < pixels.count {
            crosshairValue = String(format: "%.4g", pixels[pixelIdx])
        }

        if let wcs {
            let fitsY = Double(hdu.header.naxis2 - 1) - point.y
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            crosshairRA = FITSWCSTransform.formatRA(ra)
            crosshairDec = FITSWCSTransform.formatDec(dec)
            onCrosshairPlaced?(ra, dec)
        }
    }

    /// Update cursor readout (no permanent crosshair).
    func updateCursorInfo(at point: CGPoint) {
        guard let hdu = selectedHDU else { return }
        let pixelIdx = Int(point.y) * hdu.header.naxis1 + Int(point.x)
        if pixelIdx >= 0 && pixelIdx < pixels.count {
            cursorPixelValue = String(format: "%.4g", pixels[pixelIdx])
        }

        if let wcs {
            let fitsY = Double(hdu.header.naxis2 - 1) - point.y
            let (ra, dec) = wcs.pixelToWorld(x: point.x, y: fitsY)
            cursorRA = FITSWCSTransform.formatRA(ra)
            cursorDec = FITSWCSTransform.formatDec(dec)
        }
    }

    // MARK: - Viewport

    func applyNorthUp() {
        guard let wcs else { return }
        viewport.rotation = -wcs.northAngle * .pi / 180.0
    }

    func resetViewport() {
        viewport = FITSViewport()
    }

    #if os(macOS)
    func openWithPicker() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.title = "Open FITS File"
        // Filter in panel message since UTI for FITS doesn't exist natively
        panel.message = "Select a FITS file (.fits, .fit, .fts)"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        await open(url: url)
    }
    #endif
}
