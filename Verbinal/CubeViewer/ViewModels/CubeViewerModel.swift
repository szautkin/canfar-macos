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
    /// The file this tab shows; set when an open starts.
    private(set) var fileURL: URL?
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
    /// Metal volume path failure (pipeline / texture). Nil when healthy.
    /// Wireframe may still draw; slice mode remains available.
    var volumeRenderError: String?
    var object = ""
    var telescope = ""
    var instrument = ""
    var bunit = ""
    var hasData: Bool { cube != nil }

    /// Set by the volume view so figure export can capture the GPU render.
    /// Not observed — it's a transport closure, not UI state.
    @ObservationIgnored var volumeSnapshot: ((Int, Int, SIMD4<Float>?) -> CGImage?)?

    /// Recently opened cubes, kept across launches.
    @ObservationIgnored var recentFiles = RecentFiles.cubes
    var recents: [RecentFile] { recentFiles.items }

    // MARK: View state (shared by both modes)
    var viewMode: CubeViewMode = .slice {
        // The slice only renders while it's visible; switching back to it brings
        // it current. Avoids wasted CPU slice renders during volume-mode scrubbing.
        didSet { if viewMode == .slice && oldValue != .slice { requestSliceRender() } }
    }
    private(set) var channel = 0
    /// The slice's zoom (1 = fitted to the canvas) and pan in screen points.
    /// Kept here, not in the view, so a mark can be centred and the view
    /// survives a trip to volume mode.
    var sliceZoom: CGFloat = 1
    var slicePan: CGSize = .zero
    /// The slice canvas as last laid out.
    var sliceCanvasSize: CGSize = .zero
    static let sliceZoomRange: ClosedRange<CGFloat> = 1...20
    /// Window over the normalized [0,1] value, shared by slice cuts and the
    /// volume shader so the two modes display the same dynamic range.
    var windowLo: Float = 0
    var windowHi: Float = 1
    var stretch: FITSRenderParams.StretchMode = .linear
    var colormap: FITSRenderParams.ColormapType = .inferno
    var background: CubeBackground = .dark

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
    /// Controls the spectrum inspector requested by the toolbar or MCP.
    var showSpectrumPanel = false

    private var renderRunning = false
    private var renderPending = false

    /// GPU 3D-texture edge cap. Metal's max `type3D` dimension is 2048; 512
    /// balances spectral/spatial detail against the volume's memory budget.
    private let max3D = 512

    // MARK: - Opening

    func open(url: URL) async {
        stopPlayback()
        isLoading = true
        loadError = nil
        loadStage = "OPENING"
        loadProgress = 0
        fileName = url.lastPathComponent
        fileURL = url
        resetSliceView()
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
            addRecent(url)
            if isStreamed {
                toast = "Large cube — slices stream from disk; the spectrum probe needs a memory-resident cube."
            }
        } catch {
            Self.logger.error("Cube open failed: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Re-open a recent cube by resolving its security-scoped bookmark.
    func openRecent(_ recent: RecentFile) {
        guard let url = recentFiles.resolve(recent) else {
            toast = "“\(recent.name)” is no longer available."
            return
        }
        Task { await open(url: url) }
    }

    private func addRecent(_ url: URL) {
        recentFiles.add(url)
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
    #endif

    // MARK: - Channel scrubbing

    /// Set the active channel and re-render the slice (coalesced — slider-safe).
    func setChannel(_ value: Int) {
        let clamped = max(0, min(max(nz - 1, 0), value))
        guard clamped != channel else { return }
        channel = clamped
        updateSpectralReadout()
        requestSliceRender()
    }

    func stepChannel(_ delta: Int) { setChannel(channel + delta) }

    // MARK: - Slice view

    /// The slice on `canvasSize` (default: as last laid out); nil before a cube.
    func sliceFrame(canvasSize: CGSize? = nil) -> CubeSliceFrame? {
        CubeSliceFrame(nx: nx, ny: ny, canvas: canvasSize ?? sliceCanvasSize, zoom: sliceZoom, pan: slicePan)
    }

    func resetSliceView() {
        sliceZoom = 1
        slicePan = .zero
    }

    /// Zoom the slice, keeping the point under `anchor` (default: the
    /// canvas centre) still.
    func zoomSlice(to zoom: CGFloat, keeping anchor: CGPoint? = nil) {
        let zoom = min(max(zoom, Self.sliceZoomRange.lowerBound), Self.sliceZoomRange.upperBound)
        if let frame = sliceFrame() {
            let at = anchor ?? CGPoint(x: frame.canvas.width / 2, y: frame.canvas.height / 2)
            slicePan = zoom == 1 ? .zero : frame.panKeeping(at, atZoom: zoom)
        }
        sliceZoom = zoom
    }

    /// Show voxel (x, y) of `channel` in the middle of the slice.
    func centreSlice(onVoxel x: Double, _ y: Double, channel: Int) {
        viewMode = .slice
        setChannel(channel)
        if let frame = sliceFrame() { slicePan = frame.panCentring(voxel: x, y) }
    }

    // MARK: - Slice rendering (reuses FITSRenderEngine)

    /// Map the shared normalized window onto raw cut levels for the CPU renderer,
    /// so the slice honors the exact same [lo,hi]·stretch·colormap as the volume.
    var sliceRenderParams: FITSRenderParams {
        guard let stats else { return FITSRenderParams(stretch: stretch, colormap: colormap) }
        let r = statsRange
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
    func requestSliceRender() {
        guard viewMode == .slice else { return }   // slice isn't visible in volume mode
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

    /// Update the cursor coordinate/value readout for image pixel (x, y):
    /// 0-based, continuous — a pixel's centre is a whole number.
    func updateCursor(x: Double, y: Double) async {
        if let celestial = wcs?.celestial, let sky = celestial.pixelToSky(x: x, y: y) {
            skyReadout = celestial.formatSky(lon: sky.lon, lat: sky.lat)
        } else {
            skyReadout = nil
        }
        if let cube {
            // The voxel whose square the point is in (x - 0.5 ..< x + 0.5).
            let value = await cube.valueAt(x: Int((x + 0.5).rounded(.down)), y: Int((y + 0.5).rounded(.down)), z: channel)
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
        cameraAnimationTask?.cancel()   // the human's drag wins over an agent move
        cameraAzimuth -= dx * 0.01
        cameraElevation = min(max(cameraElevation + dy * 0.01, -1.4), 1.4)
        lastCameraInteraction = Date()
    }

    func zoomCamera(_ delta: Float) {
        cameraAnimationTask?.cancel()
        cameraDistance = min(max(cameraDistance * exp(delta), 0.5), 8)
        lastCameraInteraction = Date()
    }

    private var cameraAnimationTask: Task<Void, Never>?

    /// Ease the camera to a target pose. Agent-driven moves ride this so
    /// the user sees motion they can follow instead of a hard cut; a
    /// user drag or zoom cancels it mid-flight (the human wins). Duration
    /// ≤ 0.05 s applies instantly (the Reduce-Motion path). Targets are
    /// clamped to the same bounds as the gesture handlers.
    func animateCamera(
        azimuth: Float? = nil,
        elevation: Float? = nil,
        distance: Float? = nil,
        duration: TimeInterval = 0.6
    ) {
        cameraAnimationTask?.cancel()
        lastCameraInteraction = Date()   // hold the idle auto-orbit off the move
        let start = SIMD3<Float>(cameraAzimuth, cameraElevation, cameraDistance)
        let target = SIMD3<Float>(
            azimuth ?? cameraAzimuth,
            min(max(elevation ?? cameraElevation, -1.4), 1.4),
            min(max(distance ?? cameraDistance, 0.5), 8)
        )
        guard duration > 0.05 else {
            cameraAzimuth = target.x
            cameraElevation = target.y
            cameraDistance = target.z
            return
        }
        cameraAnimationTask = Task { [weak self] in
            let steps = max(2, Int(duration * 60))
            let stepMs = max(1, Int(duration * 1000) / steps)
            for i in 1...steps {
                guard let self, !Task.isCancelled else { return }
                let t = Float(i) / Float(steps)
                let eased = t * t * (3 - 2 * t)   // smoothstep ease-in-out
                let pose = start + (target - start) * eased
                self.cameraAzimuth = pose.x
                self.cameraElevation = pose.y
                self.cameraDistance = pose.z
                self.lastCameraInteraction = Date()
                try? await Task.sleep(for: .milliseconds(stepMs))
            }
        }
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

    /// Raw-value span for mapping the normalized [0,1] window onto data values;
    /// 1 when stats are absent or the data is flat.
    private var statsRange: Float {
        guard let stats else { return 1 }
        let range = stats.hi - stats.lo
        return range == 0 ? 1 : range
    }

    /// Current window expressed in raw data values (for the readout).
    var rawWindow: (lo: Float, hi: Float) {
        guard let stats else { return (0, 1) }
        let r = statsRange
        return (stats.lo + windowLo * r, stats.lo + windowHi * r)
    }

    /// Window the full data min…max.
    func autoWindowFullRange() {
        guard let stats else { return }
        let r = statsRange
        windowLo = (stats.min - stats.lo) / r
        windowHi = (stats.max - stats.lo) / r
        requestSliceRender()
    }

    /// Window the robust p0.1…p99.9 percentile range (the load-time default).
    func autoWindowPercentile() {
        windowLo = 0
        windowHi = 1
        requestSliceRender()
    }

    // MARK: - Figure metadata (publication legend; deterministic + testable)

    /// All the numbers/labels a publication figure plate needs, computed from the
    /// cube's WCS and statistics. Deterministic (no timestamp) so it can be
    /// unit-tested against a known cube.
    func figureMetadata() -> CubeFigureMetadata {
        let raw = rawWindow
        let cel = wcs?.celestial
        let lonLabel = cel?.frame == .galactic ? "GLON" : "RA"
        let latLabel = cel?.frame == .galactic ? "GLAT" : "DEC"

        func sky(_ x: Int, _ y: Int) -> CelestialWCS.SkyReadout? {
            guard let cel, let s = cel.pixelToSky(x: Double(x), y: Double(y)) else { return nil }
            return cel.formatSky(lon: s.lon, lat: s.lat)
        }
        let raRange: String? = (nx > 1 ? zip2(sky(0, ny / 2)?.lon, sky(nx - 1, ny / 2)?.lon) : nil)
        let decRange: String? = (ny > 1 ? zip2(sky(nx / 2, 0)?.lat, sky(nx / 2, ny - 1)?.lat) : nil)

        let spec = wcs?.spectral
        let now = spec?.format(channel: channel)
        let spectralRange: String = (spec != nil && nz > 1)
            ? "\(spec!.format(channel: 0).primary) … \(spec!.format(channel: nz - 1).primary)"
            : ""

        return CubeFigureMetadata(
            title: (object.isEmpty || object == "—") ? (fileName.isEmpty ? "Cube" : fileName) : object,
            instrument: [telescope, instrument].filter { !$0.isEmpty }.joined(separator: " · "),
            fileName: fileName,
            dimensions: "\(nx) × \(ny) × \(nz)",
            valueLo: fmtValue(raw.lo),
            valueHi: fmtValue(raw.hi),
            unit: bunit,
            nan: stats.map { String(format: "%.1f%%", $0.nanFrac * 100) } ?? "—",
            mode: isStreamed ? "Streamed" : "Resident",
            stretch: stretch.rawValue,
            colormap: colormap.rawValue,
            lonLabel: lonLabel,
            latLabel: latLabel,
            raRange: raRange,
            decRange: decRange,
            channelLabel: "CH \(channel + 1)/\(nz)",
            spectral: now.map { $0.secondary.map { s in "\(now!.primary) · \(s)" } ?? $0.primary } ?? "",
            spectralRange: spectralRange
        )
    }

    private func fmtValue(_ v: Float) -> String { String(format: "%.3g", v) }
    private func zip2(_ a: String?, _ b: String?) -> String? {
        guard let a, let b else { return nil }
        return "\(a) … \(b)"
    }

    // MARK: - Volume shader inputs

    /// Stretch index matching `FITSRenderParams.StretchMode.allCases` order, fed
    /// to the Metal shader so volume and slice apply the identical stretch.
    var stretchIndex: Int32 {
        Int32(FITSRenderParams.StretchMode.allCases.firstIndex(of: stretch) ?? 0)
    }
}

/// The numbers + labels for a publication figure plate (legend, header, colorbar).
struct CubeFigureMetadata: Equatable {
    let title: String
    let instrument: String
    let fileName: String
    let dimensions: String
    let valueLo: String
    let valueHi: String
    let unit: String
    let nan: String
    let mode: String
    let stretch: String
    let colormap: String
    let lonLabel: String
    let latLabel: String
    let raRange: String?
    let decRange: String?
    let channelLabel: String
    let spectral: String
    let spectralRange: String
}

/// Background for the cube viewer display and figure export. `rgba` (kept
/// SwiftUI-free so it lives in the model) feeds both the Metal clear color and
/// a SwiftUI Color (see the `color` extension).
enum CubeBackground: String, CaseIterable, Identifiable {
    case dark, black, light
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var rgba: SIMD4<Float> {
        switch self {
        case .dark: return SIMD4(0.02, 0.03, 0.06, 1)
        case .black: return SIMD4(0, 0, 0, 1)
        case .light: return SIMD4(0.96, 0.96, 0.96, 1)
        }
    }
}
