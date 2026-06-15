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
    var toast: String?
    var showGuide = false

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

    /// Set by the volume view so figure export can capture the GPU render.
    /// Not observed — it's a transport closure, not UI state.
    @ObservationIgnored var volumeSnapshot: ((Int, Int) -> CGImage?)?

    // MARK: View state (shared by both modes)
    var viewMode: CubeViewMode = .slice
    private(set) var channel = 0
    /// Window over the normalized [0,1] value, shared by slice cuts and the
    /// volume shader so the two modes display the same dynamic range.
    var windowLo: Float = 0
    var windowHi: Float = 1
    var stretch: FITSRenderParams.StretchMode = .linear
    var colormap: FITSRenderParams.ColormapType = .inferno

    // MARK: Volume-only controls
    var density: Float = 1.0
    var spectralScale: Float = 1.5
    var mip = false
    var showSlicePlane = true
    var autoOrbit = false {
        didSet { autoOrbit ? startAutoOrbitLoop() : stopAutoOrbitLoop() }
    }

    // Orbit camera — owned here so the axis-caption overlay can track the orbit.
    var cameraAzimuth: Float = 0.7
    var cameraElevation: Float = 0.5
    var cameraDistance: Float = 2.6
    private var lastCameraInteraction = Date()
    private var autoOrbitTask: Task<Void, Never>?
    /// Opacity transfer function: control points (value ∈ [0,1], alpha ∈ [0,1]).
    var transferFunction: [SIMD2<Float>] = [
        SIMD2(0.0, 0.0), SIMD2(0.45, 0.05), SIMD2(0.75, 0.45), SIMD2(1.0, 1.0),
    ]
    /// Ray-march step count (volume quality). Higher = sharper but slower.
    var volumeSteps: Float = 384

    // MARK: Playback
    private(set) var isPlaying = false
    var playbackFPS: Double = 12
    private var playbackTask: Task<Void, Never>?

    // MARK: Scrubber waveform (cube-mean per channel; RAM cubes only)
    private(set) var channelProfile: [Float]?

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

    private var renderRunning = false
    private var renderPending = false

    /// GPU 3D-texture edge cap. Metal's max `type3D` dimension is 2048; 512
    /// balances spectral/spatial detail against the volume's memory budget.
    private let max3D = 512

    var channelCount: Int { nz }

    // MARK: - Opening

    func open(url: URL) async {
        stopPlayback()
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
            self.channelProfile = await cube.channelMeans()
            self.isStreamed = await cube.isStreamed
            self.cube = cube
            self.channel = nz / 2
            updateSpectralReadout()
            await renderSliceAsync()
            if isStreamed {
                toast = "Large cube — slices stream from disk; the spectrum probe needs a memory-resident cube."
            }
        } catch {
            Self.logger.error("Cube open failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Download a remote cube to a temp file, then open it locally — far fewer
    /// requests than range-streaming a moderate-size sample.
    func openRemote(url: URL) async {
        stopPlayback()
        isLoading = true
        loadError = nil
        loadStage = "DOWNLINK"
        loadProgress = 0
        fileName = url.lastPathComponent
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw NSError(domain: "CubeViewer", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))"])
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: downloaded, to: dest)
            await open(url: dest)
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    /// Sample cubes for the empty state (hosted on the v-cube demo site).
    static let samples: [CubeSample] = CubeSample.defaults

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

    /// Request a slice re-render. Single-flight + coalescing: rapid channel or
    /// window changes (scrubbing, playback) always converge to the *latest*
    /// frame instead of being dropped, so the slice never freezes during play.
    func renderSliceDebounced() {
        renderPending = true
        guard !renderRunning else { return }
        renderRunning = true
        Task { [weak self] in
            guard let self else { return }
            while self.renderPending {
                self.renderPending = false
                await self.renderSliceAsync()
            }
            self.renderRunning = false
        }
    }

    private func renderSliceAsync() async {
        guard let cube, nx > 0, ny > 0 else { return }
        isRendering = true
        defer { isRendering = false }
        let width = nx, height = ny
        let params = sliceRenderParams
        let plane: [Float]
        do {
            plane = try await cube.plane(channel)
        } catch {
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            FITSRenderEngine.render(pixels: plane, width: width, height: height, params: params)
        }.value
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

    // MARK: - Playback (animate through channels)

    func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    func startPlayback() {
        guard nz > 1, !isPlaying else { return }
        isPlaying = true
        // Task created in a @MainActor method is main-actor-isolated, so the
        // property reads below are synchronous (no data race).
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                let interval = 1.0 / max(self.playbackFPS, 0.5)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, self.isPlaying else { break }
                self.setChannel(self.channel + 1 >= self.nz ? 0 : self.channel + 1)
            }
        }
    }

    func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    // MARK: - Camera

    func orbitCamera(dx: Float, dy: Float) {
        cameraAzimuth -= dx * 0.01
        cameraElevation = min(max(cameraElevation + dy * 0.01, -1.4), 1.4)
        lastCameraInteraction = Date()
    }

    func zoomCamera(_ delta: Float) {
        cameraDistance = min(max(cameraDistance * exp(delta), 0.5), 8)
        lastCameraInteraction = Date()
    }

    private func startAutoOrbitLoop() {
        autoOrbitTask?.cancel()
        autoOrbitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.autoOrbit else { break }
                if self.viewMode == .volume, self.hasData,
                   Date().timeIntervalSince(self.lastCameraInteraction) > 6 {
                    self.cameraAzimuth += 0.0016
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopAutoOrbitLoop() {
        autoOrbitTask?.cancel()
        autoOrbitTask = nil
    }

    // MARK: - Window helpers

    /// Current window expressed in raw data values (for the readout).
    var rawWindow: (lo: Float, hi: Float) {
        guard let stats else { return (0, 1) }
        let range = stats.hi - stats.lo
        let r = range == 0 ? 1 : range
        return (stats.lo + windowLo * r, stats.lo + windowHi * r)
    }

    /// Window the full data min…max.
    func autoWindowFullRange() {
        guard let stats else { return }
        let range = stats.hi - stats.lo
        let r = range == 0 ? 1 : range
        windowLo = (stats.min - stats.lo) / r
        windowHi = (stats.max - stats.lo) / r
        renderSliceDebounced()
    }

    /// Window the robust p0.1…p99.9 percentile range (the load-time default).
    func autoWindowPercentile() {
        windowLo = 0
        windowHi = 1
        renderSliceDebounced()
    }

    // MARK: - Volume shader inputs

    /// Stretch index matching `FITSRenderParams.StretchMode.allCases` order, fed
    /// to the Metal shader so volume and slice apply the identical stretch.
    var stretchIndex: Int32 {
        Int32(FITSRenderParams.StretchMode.allCases.firstIndex(of: stretch) ?? 0)
    }
}

/// A downloadable sample cube shown in the empty state.
struct CubeSample: Identifiable {
    let id = UUID()
    let label: String
    let size: String
    let url: URL
    let tip: String

    static let defaults: [CubeSample] = {
        let base = "https://v-cube.starai.ca"
        func make(_ label: String, _ size: String, _ path: String, _ tip: String) -> CubeSample? {
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: base + encoded) else { return nil }
            return CubeSample(label: label, size: size, url: url, tip: tip)
        }
        return [
            make("JCMT · CO line cube", "110 MB", "/data_cubes/JCMT/jcmth20260604_00047_06_reduced001_obs_000.fits", "61×61×3872 — high-resolution spectral line cube."),
            make("JWST MIRI MRS · IFU", "130 MB", "/data_cubes/JWST/product/jw01023011001_02101_00003_mirifushort_s3d.fits", "43×45×4404 — WAVE-TAB wavelengths, ~58% NaN border."),
            make("JWST NIRSpec · IFU", "37 MB", "/data_cubes/JWST 3/product/jw01409133001_02101_00001_nrs1_s3d.fits", "51×49×972 — compact target, fastest sample."),
            make("JWST NIRSpec · lamp cal", "61 MB", "/data_cubes/JWST 2/product/jw01132002001_02128_00001_nrs1_s3d.fits", "30×37×3610 — internal lamp exposure, no sky WCS."),
        ].compactMap { $0 }
    }()
}
