// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CoreGraphics
import os
import VerbinalKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Per-cube view model: owns one `CubeModel` (the VerbinalKit actor), drives
/// ingest, and holds all UI state shared by slice and volume modes. Slice
/// rendering reuses `FITSRenderEngine` (the same CPU renderer as the 2D FITS
/// viewer); volume rendering hands `VolumeData` to the Metal renderer. The two
/// modes share one window/stretch/colormap so they always agree.
@Observable
@MainActor
final class CubeViewerModel: Identifiable {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "CubeViewer")
    let id = UUID()

    // MARK: Loading
    var isLoading = false
    var loadError: String?
    var loadStage = ""
    var loadProgress: Double = 0
    var fileName = ""

    // MARK: Data (valid after a successful open)
    private(set) var cube: CubeModel?
    private(set) var stats: CubeStats?
    private(set) var wcs: CubeWCS?
    private(set) var volumeData: VolumeData?
    private(set) var nx = 0
    private(set) var ny = 0
    private(set) var nz = 0
    private(set) var isStreamed = false
    var object = ""
    var telescope = ""
    var instrument = ""
    var bunit = ""
    var hasData: Bool { cube != nil }

    // MARK: View state (shared by both modes)
    var viewMode: CubeViewMode = .slice
    private(set) var channel = 0
    /// Window over the normalized [0,1] value, shared by slice cuts and the
    /// volume shader so the two modes display the same dynamic range.
    var windowLo: Float = 0
    var windowHi: Float = 1
    var stretch: FITSRenderParams.StretchMode = .linear
    var colormap: FITSRenderParams.ColormapType = .viridis

    // MARK: Volume-only controls
    var density: Float = 1.0
    var spectralScale: Float = 1.5
    var mip = false
    /// Opacity transfer function: control points (value ∈ [0,1], alpha ∈ [0,1]).
    var transferFunction: [SIMD2<Float>] = [
        SIMD2(0.0, 0.0), SIMD2(0.45, 0.05), SIMD2(0.75, 0.45), SIMD2(1.0, 1.0),
    ]

    // MARK: Slice render output
    private(set) var sliceImage: CGImage?
    private(set) var isRendering = false

    // MARK: Readouts
    var spectralReadout: SpectralWCS.Readout?
    var skyReadout: CelestialWCS.SkyReadout?
    var cursorValue = ""

    // MARK: Spectrum probe
    private(set) var probeSpectrum: [Float]?
    private(set) var probePoint: (x: Int, y: Int)?
    var probeUnavailableReason: String?

    private var sliceDebounce: Task<Void, Never>?

    /// GPU 3D-texture edge cap. Metal's max `type3D` dimension is 2048; 512
    /// balances spectral/spatial detail against the volume's memory budget.
    private let max3D = 512

    var channelCount: Int { nz }

    // MARK: - Opening

    func open(url: URL) async {
        isLoading = true
        loadError = nil
        loadStage = "OPENING"
        loadProgress = 0
        fileName = url.lastPathComponent
        Self.logger.info("Opening cube: \(url.lastPathComponent, privacy: .public)")

        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let source = try LocalFileCubeSource(url: url)
            let cube = try await CubeModel.open(source: source)
            try await cube.ingest(max3D: max3D) { [weak self] progress in
                Task { @MainActor in
                    self?.loadStage = progress.stage
                    self?.loadProgress = progress.fraction
                }
            }

            // `let` members of the actor are nonisolated; vars/computed need await.
            self.nx = cube.nx
            self.ny = cube.ny
            self.nz = cube.nz
            self.object = cube.object
            self.telescope = cube.telescope
            self.instrument = cube.instrument
            self.bunit = cube.bunit
            self.stats = await cube.stats
            self.wcs = await cube.wcs
            self.volumeData = await cube.volume
            self.isStreamed = await cube.isStreamed
            self.cube = cube
            self.channel = nz / 2
            updateSpectralReadout()
            await renderSliceAsync()
        } catch {
            Self.logger.error("Cube open failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    #if os(macOS)
    func openWithPicker() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["fits", "fit", "fts"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a FITS spectral cube"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await open(url: url)
    }

    /// Save the current rendered slice (a CGImage from FITSRenderEngine) as PNG.
    func exportSlicePNG() {
        guard let image = sliceImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let base = (object.isEmpty || object == "—") ? "cube" : object
        panel.nameFieldStringValue = "\(base)_ch\(channel + 1).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
    #endif

    // MARK: - Channel scrubbing

    /// Set the active channel and re-render the slice (debounced — slider-safe).
    func setChannel(_ value: Int) {
        let clamped = max(0, min(max(nz - 1, 0), value))
        guard clamped != channel else { return }
        channel = clamped
        updateSpectralReadout()
        renderSliceDebounced()
    }

    func stepChannel(_ delta: Int) { setChannel(channel + delta) }

    // MARK: - Slice rendering (reuses FITSRenderEngine)

    /// Map the shared normalized window onto raw cut levels for the CPU renderer,
    /// so the slice honors the exact same [lo,hi]·stretch·colormap as the volume.
    var sliceRenderParams: FITSRenderParams {
        guard let stats else { return FITSRenderParams(stretch: stretch, colormap: colormap) }
        let range = stats.hi - stats.lo
        let r = range == 0 ? 1 : range
        return FITSRenderParams(
            minCut: stats.lo + windowLo * r,
            maxCut: stats.lo + windowHi * r,
            stretch: stretch,
            colormap: colormap
        )
    }

    /// Re-render after a window/stretch/colormap change (debounced).
    func renderSliceDebounced() {
        sliceDebounce?.cancel()
        sliceDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, !Task.isCancelled else { return }
            await self.renderSliceAsync()
        }
    }

    private func renderSliceAsync() async {
        guard let cube, nx > 0, ny > 0 else { return }
        isRendering = true
        defer { isRendering = false }
        let requested = channel
        let width = nx, height = ny
        let params = sliceRenderParams
        let plane: [Float]
        do {
            plane = try await cube.plane(requested)
        } catch {
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            FITSRenderEngine.render(pixels: plane, width: width, height: height, params: params)
        }.value
        // Drop stale renders if the user kept scrubbing while we awaited.
        guard requested == channel else { return }
        sliceImage = image
    }

    // MARK: - Readouts & probe

    private func updateSpectralReadout() {
        spectralReadout = wcs?.spectral.format(channel: channel)
    }

    /// Update the cursor coordinate/value readout for image pixel (x, y), 0-based.
    func updateCursor(x: Double, y: Double) async {
        if let celestial = wcs?.celestial, let sky = celestial.pixelToSky(x: x, y: y) {
            skyReadout = celestial.formatSky(lon: sky.lon, lat: sky.lat)
        } else {
            skyReadout = nil
        }
        if let cube {
            let value = await cube.valueAt(x: Int(x.rounded()), y: Int(y.rounded()), z: channel)
            cursorValue = value.isNaN ? "—" : String(format: "%.4g %@", value, bunit)
        }
    }

    func clearCursor() {
        skyReadout = nil
        cursorValue = ""
    }

    /// Probe the spectrum through image pixel (x, y) — RAM cubes only.
    func probe(x: Int, y: Int) async {
        guard let cube else { return }
        if isStreamed {
            probeUnavailableReason = "Spectrum probe needs the whole cube in memory (this one is streamed)."
            probeSpectrum = nil
            probePoint = nil
            return
        }
        probeUnavailableReason = nil
        probeSpectrum = await cube.spectrum(x: x, y: y)
        probePoint = probeSpectrum == nil ? nil : (x, y)
    }

    func clearProbe() {
        probeSpectrum = nil
        probePoint = nil
        probeUnavailableReason = nil
    }

    // MARK: - Volume shader inputs

    /// Stretch index matching `FITSRenderParams.StretchMode.allCases` order, fed
    /// to the Metal shader so volume and slice apply the identical stretch.
    var stretchIndex: Int32 {
        Int32(FITSRenderParams.StretchMode.allCases.firstIndex(of: stretch) ?? 0)
    }
}
