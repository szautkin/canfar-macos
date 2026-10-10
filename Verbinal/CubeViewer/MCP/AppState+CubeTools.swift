// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit
import MCPCore

/// Cube viewer control.
extension AppState {
    private nonisolated static func closedCubeView() -> GetCubeViewTool.Output {
        GetCubeViewTool.Output(
            isOpen: false, fileName: nil, nx: nil, ny: nil, nz: nil, channel: nil,
            viewMode: nil, colormap: nil, stretch: nil, windowLo: nil, windowHi: nil,
            density: nil, maxIntensityProjection: nil, autoOrbit: nil, isPlaying: nil,
            background: nil, spectralScale: nil, quality: nil, showSlicePlane: nil,
            playbackFPS: nil, opacityCurve: nil, camera: nil)
    }

    func makeGetCubeImageTool() -> ViewerImageTool {
        ViewerImageTool.cube { [weak self] maxSide in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else {
                    throw ToolFailureReason.targetNotResolved("No cube is open in the Cube Viewer — open one first")
                }
                let marks = model.markTarget.map { self.marks.marks(on: $0) } ?? []
                guard let drawn = CubeViewPicture.render(model: model, marks: marks, maxSide: maxSide) else {
                    throw ToolFailureReason.backendError("the Cube Viewer has not drawn its \(model.viewMode.rawValue) yet")
                }
                return ViewerPicture(
                    image: AgentImageEncoding.fitting(drawn, maxSide: maxSide),
                    caption: [
                        "file": .string(model.fileURL?.path ?? model.fileName),
                        "viewMode": .string(model.viewMode.rawValue),
                        "channel": .int(model.channel),
                        "channels": .int(model.nz),
                        "colormap": .string(model.colormap.rawValue),
                        "background": .string(model.background.rawValue),
                        "marks": .int(marks.count),
                        "spectrumShown": .bool(CubeViewPicture.showsSpectrum(model)),
                    ])
            }
        }
    }

    func makeGetCubeViewTool() -> GetCubeViewTool {
        GetCubeViewTool(snapshot: { [weak self] in
            guard let self else { return Self.closedCubeView() }
            return await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else { return Self.closedCubeView() }
                return GetCubeViewTool.Output(
                    isOpen: true,
                    fileName: model.fileName,
                    nx: model.nx, ny: model.ny, nz: model.nz,
                    channel: model.channel,
                    viewMode: model.viewMode == .slice ? "slice" : "volume",
                    colormap: model.colormap.rawValue,
                    stretch: model.stretch.rawValue,
                    windowLo: Double(model.windowLo),
                    windowHi: Double(model.windowHi),
                    density: Double(model.density),
                    maxIntensityProjection: model.mip,
                    autoOrbit: model.autoOrbit,
                    isPlaying: model.isPlaying,
                    background: model.background.rawValue,
                    spectralScale: Double(model.spectralScale),
                    quality: Double(model.volumeSteps),
                    showSlicePlane: model.showSlicePlane,
                    playbackFPS: model.playbackFPS,
                    opacityCurve: model.transferFunction.map { [Double($0.x), Double($0.y)] },
                    camera: .init(
                        azimuthDeg: Double(model.cameraAzimuth) * 180 / .pi,
                        elevationDeg: Double(model.cameraElevation) * 180 / .pi,
                        distance: Double(model.cameraDistance)))
            }
        })
    }

    func makeSetCubeViewTool() -> SetCubeViewTool {
        let activity = agentsService.activityStore
        return SetCubeViewTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else { return "No cube is open in the Cube Viewer" }
                if let mode = args.viewMode {
                    switch mode {
                    case "slice": model.viewMode = .slice
                    case "volume": model.viewMode = .volume
                    default: return "Unknown viewMode '\(mode)'"
                    }
                }
                if let ch = args.channel {
                    guard ch >= 0 && ch < model.nz else {
                        return "channel \(ch) out of range 0…\(model.nz - 1)"
                    }
                    model.setChannel(ch)
                }
                if let c = args.colormap {
                    guard let map = FITSRenderParams.ColormapType(rawValue: c) else { return "Unknown colormap '\(c)'" }
                    model.colormap = map
                }
                if let s = args.stretch {
                    guard let mode = FITSRenderParams.StretchMode(rawValue: s) else { return "Unknown stretch '\(s)'" }
                    model.stretch = mode
                }
                if args.windowLo != nil || args.windowHi != nil {
                    let lo = args.windowLo.map(Float.init) ?? model.windowLo
                    let hi = args.windowHi.map(Float.init) ?? model.windowHi
                    guard lo < hi else { return "windowLo must be < windowHi" }
                    model.windowLo = lo
                    model.windowHi = hi
                }
                if let d = args.density {
                    guard d >= 0 else { return "density must be ≥ 0" }
                    model.density = Float(d)
                }
                if let mip = args.maxIntensityProjection { model.mip = mip }
                if let orbit = args.autoOrbit { model.autoOrbit = orbit }
                if let playing = args.playing {
                    if playing { model.startPlayback() } else { model.stopPlayback() }
                }
                if let bg = args.background {
                    guard let value = CubeBackground(rawValue: bg) else { return "Unknown background '\(bg)'" }
                    model.background = value
                }
                if let scale = args.spectralScale {
                    guard (0.5...4).contains(scale) else { return "spectralScale must be 0.5–4" }
                    model.spectralScale = Float(scale)
                }
                if let quality = args.quality {
                    guard (96...768).contains(quality) else { return "quality must be 96–768" }
                    model.volumeSteps = Float(quality)
                }
                if let marker = args.showSlicePlane { model.showSlicePlane = marker }
                if let fps = args.playbackFPS {
                    guard (0.5...60).contains(fps) else { return "playbackFPS must be 0.5–60" }
                    model.playbackFPS = fps
                }
                if let curve = args.opacityCurve {
                    if let error = SetCubeViewTool.validateOpacityCurve(curve) { return error }
                    model.transferFunction = curve.map { SIMD2(Float($0[0]), Float($0[1])) }
                }
                if let auto = args.autoWindow {
                    switch auto {
                    case "auto": model.autoWindow()
                    case "percentile": model.autoWindowPercentile()
                    case "full": model.autoWindowFullRange()
                    default: return "Unknown autoWindow '\(auto)' — use auto, percentile or full"
                    }
                }
                // The UI's bindings request a slice re-render on every
                // slice-affecting change; tool-driven mutations must too,
                // or the slice pane goes stale until the next interaction.
                if args.colormap != nil || args.stretch != nil
                    || args.windowLo != nil || args.windowHi != nil {
                    model.requestSliceRender()
                }
                if args.reveal == true { self.navigateTo(.cubeViewer) }
                activity.append(.live(
                    kind: "set_cube_view", summary: "Adjusted the Cube view",
                    origin: .external(clientID: "set_cube_view")))
                return nil
            }
        })
    }

    func makeSetCubeCameraTool() -> SetCubeCameraTool {
        let activity = agentsService.activityStore
        return SetCubeCameraTool(apply: { [weak self] args in
            guard let self else { return .rejected("App state unavailable") }
            return await MainActor.run {
                let model = self.cubeViewer
                guard model.hasData else { return .rejected("No cube is open in the Cube Viewer") }
                if let z = args.zoomFactor, z <= 0 { return .rejected("zoomFactor must be > 0") }

                let degToRad = Float.pi / 180
                var azimuth = args.azimuthDeg.map { Float($0) * degToRad } ?? model.cameraAzimuth
                var elevation = args.elevationDeg.map { Float($0) * degToRad } ?? model.cameraElevation
                var distance = args.distance.map(Float.init) ?? model.cameraDistance
                if let d = args.orbitByAzimuthDeg { azimuth += Float(d) * degToRad }
                if let d = args.orbitByElevationDeg { elevation += Float(d) * degToRad }
                if let z = args.zoomFactor { distance /= Float(z) }
                elevation = CubeViewerModel.clamped(elevation: elevation)
                distance = CubeViewerModel.clamped(distance: distance)

                // The camera only exists in volume mode — switch so the
                // user actually sees the move.
                if model.viewMode != .volume { model.viewMode = .volume }
                if args.reveal == true { self.navigateTo(.cubeViewer) }

                let duration = (self.reduceMotion || args.animated == false) ? 0 : 0.6
                model.animateCamera(
                    azimuth: azimuth, elevation: elevation, distance: distance,
                    duration: duration)

                activity.append(.live(
                    kind: "set_cube_camera", summary: "Moved the Cube camera",
                    origin: .external(clientID: "set_cube_camera")))
                // The target it moves to, as asked or held to the bounds — not
                // where the easing is now — to the hundredth (plan 30 N7).
                func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
                return .applied(SetCubeCameraTool.Pose(
                    azimuthDeg: rounded(Double(azimuth) * 180 / .pi),
                    elevationDeg: rounded(Double(elevation) * 180 / .pi),
                    distance: rounded(Double(distance))))
            }
        })
    }

    func makeProbeCubeSpectrumTool() -> ProbeCubeSpectrumTool {
        ProbeCubeSpectrumTool(probe: { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            return try await self.probeCubeSpectrum(args)
        })
    }

    func makeListRecentCubesTool() -> ListRecentFilesTool {
        ListRecentFilesTool.cubes { await RecentFiles.cubes.present().map { .init(name: $0.name, path: $0.path) } }
    }

    func makeListRecentFITSTool() -> ListRecentFilesTool {
        ListRecentFilesTool.fits { await RecentFiles.fits.present().map { .init(name: $0.name, path: $0.path) } }
    }

    func makeShowCubeSpectrumTool() -> ShowCubeSpectrumTool {
        ShowCubeSpectrumTool(apply: { [weak self] visible in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard self.cubeViewer.hasData else { return "No cube is open in the Cube Viewer" }
                self.cubeViewer.showSpectrumPanel = visible
                self.navigateTo(.cubeViewer)
                return nil
            }
        })
    }

    func makeGetCubeChannelProfileTool() -> GetCubeChannelProfileTool {
        GetCubeChannelProfileTool(profile: { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let cube = self.cubeViewer
                guard cube.hasData else { throw ToolFailureReason.targetNotResolved("No cube is open in the Cube Viewer") }
                guard let means = cube.channelProfile, !means.isEmpty else {
                    throw ToolFailureReason.targetNotResolved("This cube has no channel profile")
                }
                let spectral = cube.wcs?.spectral
                // The spectrum's binning, by default to at most `profilePoints` values (plan 30 P).
                let bin = args.bin ?? CubeSpectrumSlice.bin(toAtMost: CubeSpectrumSlice.profilePoints, count: means.count,
                                                            first: args.firstChannel, last: args.lastChannel)
                let slice: CubeSpectrumSlice
                switch CubeSpectrumSlice.make(means, first: args.firstChannel, last: args.lastChannel, bin: bin,
                                              axisValue: spectral.map { axis in { axis.value(atChannel: $0) } }) {
                case .success(let made): slice = made
                case .failure(let problem): throw ToolFailureReason.invalidArgument(problem.message)
                }
                let unit = cube.bunit.trimmingCharacters(in: .whitespaces)
                return GetCubeChannelProfileTool.Output(
                    channelCount: cube.nz, firstChannel: slice.first, lastChannel: slice.last, bin: slice.bin,
                    unit: unit.isEmpty ? nil : unit,
                    spectralAxis: spectral.map { .init(type: $0.ctype, unit: $0.cunit) },
                    axis: slice.axis, means: slice.values, blankedChannels: slice.blanked, truncated: slice.truncated)
            }
        })
    }

    func makeSetCubeTransferTool() -> SetCubeTransferTool {
        SetCubeTransferTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let cube = self.cubeViewer
                guard cube.hasData else { return "No cube is open in the Cube Viewer" }
                if args.reset == true {
                    cube.transferFunction = [SIMD2(0, 0), SIMD2(0.45, 0.05), SIMD2(0.75, 0.45), SIMD2(1, 1)]
                } else if let curve = args.opacityCurve {
                    if let error = SetCubeViewTool.validateOpacityCurve(curve) { return error }
                    cube.transferFunction = curve.map { SIMD2(Float($0[0]), Float($0[1])) }
                } else { return "Pass opacityCurve or reset: true" }
                self.navigateTo(.cubeViewer)
                return nil
            }
        })
    }

    func makeSwitchCubeTabTool() -> SwitchCubeTabTool {
        SwitchCubeTabTool(apply: { [weak self] index in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                guard self.cubeTabHost.tabs.indices.contains(index) else {
                    return "index \(index) out of range 0…\(max(0, self.cubeTabHost.tabs.count - 1))"
                }
                self.cubeTabHost.activeTabIndex = index
                self.navigateTo(.cubeViewer)
                return nil
            }
        })
    }

    private func probeCubeSpectrum(_ args: ProbeCubeSpectrumTool.Args) async throws -> ProbeCubeSpectrumTool.Output {
        let (x, y) = (args.x, args.y)
        let model = cubeViewer
        guard model.hasData else {
            throw ToolFailureReason.targetNotResolved(
                "No cube is open in the Cube Viewer — call navigate_to(mode: cubeViewer) after open_cube, or open a cube first.")
        }
        guard x >= 0, y >= 0, x < model.nx, y < model.ny else {
            throw ToolFailureReason.invalidArgument("pixel (\(x), \(y)) outside \(model.nx)×\(model.ny)")
        }
        if model.isStreamed {
            throw ToolFailureReason.invalidArgument(
                "Spectrum probe needs the whole cube in RAM. This cube is streamed (too large to load fully). Use get_cube_view / get_cube_channel_profile instead — do not request a full in-memory load (OOM risk).")
        }
        await model.probe(x: x, y: y)
        guard let spectrum = model.probeSpectrum else {
            throw ToolFailureReason.backendError(model.probeUnavailableReason ?? "spectrum unavailable")
        }
        let spectral = model.wcs?.spectral
        let slice: CubeSpectrumSlice
        switch CubeSpectrumSlice.make(spectrum, first: args.firstChannel, last: args.lastChannel, bin: args.bin,
                                      axisValue: spectral.map { axis in { axis.value(atChannel: $0) } }) {
        case .success(let made): slice = made
        case .failure(let problem): throw ToolFailureReason.invalidArgument(problem.message)
        }
        let unit = model.bunit.trimmingCharacters(in: .whitespaces)
        return ProbeCubeSpectrumTool.Output(
            x: x, y: y, channelCount: model.nz,
            firstChannel: slice.first, lastChannel: slice.last, bin: slice.bin,
            unit: unit.isEmpty ? nil : unit,
            spectralAxis: spectral.map { .init(type: $0.ctype, unit: $0.cunit) },
            axis: slice.axis, spectrum: slice.values, blankedChannels: slice.blanked, truncated: slice.truncated)
    }
}
