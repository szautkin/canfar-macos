// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Slice mode: the active channel rendered at native resolution (via the shared
/// `FITSRenderEngine`), a floating cursor readout, a WCS + spectral coordinate
/// bar, a timeline scrubber (play + waveform), and click-to-probe spectrum.
struct CubeSliceView: View {
    let model: CubeViewerModel
    /// Marks drawn and edited on the slice.
    var marks: MarkEditor?
    /// Search at a sky position (a mark's Search Here).
    var search: (Double, Double) -> Void = { _, _ in }
    @State private var hoverLocation: CGPoint?

    /// Zoom per scroll notch, as in the FITS viewer.
    private static let scrollZoomFactor: CGFloat = 1.1

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            coordinateBar
        }
    }

    // MARK: Image

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                model.background.color
                if let image = model.sliceImage {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(model.sliceZoom)
                        .offset(model.slicePan)
                } else if model.isRendering {
                    ProgressView()
                }

                if let marks, let target = model.markTarget,
                   let projection = model.sliceMarkProjection(canvasSize: geo.size) {
                    MarkOverlay(editor: marks, target: target, projection: projection)
                }

                #if os(macOS)
                ScrollCaptureView(
                    onScroll: { delta, location in
                        let factor = delta > 0 ? Self.scrollZoomFactor : 1 / Self.scrollZoomFactor
                        model.zoomSlice(to: model.sliceZoom * factor, keeping: location)
                    },
                    onPan: { dx, dy in panSlice(dx, dy) },
                    onClick: { location in probe(at: location, canvas: geo.size) },
                    onDrag: { dx, dy in panSlice(dx, dy) },
                    onHover: { location in hover(at: location, canvas: geo.size) },
                    onMagnify: { magnification in
                        model.zoomSlice(to: model.sliceZoom * (1 + magnification), keeping: hoverLocation)
                    },
                    onHoverEnd: {
                        hoverLocation = nil
                        model.clearCursor()
                    },
                    pointer: markPointer(canvasSize: geo.size),
                    // Keys stay with the viewer's own handler (channels, play).
                    takesKeyFocus: false)
                #endif

                if model.probePoint != nil || model.probeUnavailableReason != nil {
                    spectrumOverlay
                }

                if let location = hoverLocation, !model.cursorValue.isEmpty {
                    cursorChip
                        .position(
                            x: min(max(location.x + 90, 70), geo.size.width - 70),
                            y: max(location.y - 34, 28)
                        )
                        .allowsHitTesting(false)
                }

                if let marks {
                    MarkNamingLayer(editor: marks, target: model.markTarget,
                                    projection: model.sliceMarkProjection(canvasSize: geo.size), canvas: geo.size)
                }
            }
            .clipped()
            .help("Drag or scroll to pan, ⌘-scroll or pinch to zoom, double-click to reset, click to probe a spectrum")
            .onAppear { model.sliceCanvasSize = geo.size }
            .onChange(of: geo.size) { _, size in model.sliceCanvasSize = size }
        }
    }

    private func panSlice(_ dx: CGFloat, _ dy: CGFloat) {
        model.slicePan.width += dx
        model.slicePan.height += dy
    }

    /// The spectrum through the voxel whose square was clicked.
    private func probe(at location: CGPoint, canvas: CGSize) {
        guard let voxel = model.sliceFrame(canvasSize: canvas)?.voxelIndex(atScreen: location) else { return }
        Task { await model.probe(x: voxel.x, y: voxel.y) }
    }

    private func hover(at location: CGPoint, canvas: CGSize) {
        hoverLocation = location
        if let voxel = model.sliceFrame(canvasSize: canvas)?.voxel(atScreen: location) {
            Task { await model.updateCursor(x: voxel.x, y: voxel.y) }
        }
    }

    #if os(macOS)
    private func markPointer(canvasSize: CGSize) -> ScrollCaptureNSView.Pointer? {
        guard let marks, let target = model.markTarget else { return nil }
        let model = self.model
        return .marks(marks, on: target,
                      host: CubeMarkCommands(cube: model, editor: marks, target: target, search: search),
                      projection: { model.sliceMarkProjection(canvasSize: canvasSize) },
                      emptyDoubleClick: { model.resetSliceView() })
    }
    #endif

    /// Floating readout that follows the cursor (sky + spectral + value).
    private var cursorChip: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let sky = model.skyReadout {
                Text("\(sky.lonLabel) \(sky.lon)")
                Text("\(sky.latLabel) \(sky.lat)")
            }
            if let readout = model.spectralReadout {
                Text(readout.primary).foregroundStyle(.secondary)
            }
            Text(model.cursorValue).foregroundStyle(.orange)
        }
        .font(.caption2.monospaced())
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    @ViewBuilder
    private var spectrumOverlay: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let point = model.probePoint {
                        Text("Spectrum @ (\(point.x), \(point.y))").font(.caption.bold())
                    } else {
                        Text("Spectrum probe").font(.caption.bold())
                    }
                    Spacer()
                    Button { model.clearProbe() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close spectrum")
                    .accessibilityLabel("Close spectrum")
                }
                if let spectrum = model.probeSpectrum, spectrum.contains(where: { $0.isFinite }) {
                    CubeSpectrumView(spectrum: spectrum, channel: model.channel) { model.setChannel($0) }
                        .frame(height: 90)
                } else if let reason = model.probeUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).frame(height: 90)
                } else {
                    Text("NO SIGNAL").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).frame(height: 90)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    // MARK: Coordinate bar

    private var coordinateBar: some View {
        HStack(spacing: 16) {
            if let sky = model.skyReadout {
                Label("\(sky.lonLabel) \(sky.lon)   \(sky.latLabel) \(sky.lat)", systemImage: "scope")
            }
            if !model.cursorValue.isEmpty {
                Text(model.cursorValue)
            }
            Spacer()
            if let readout = model.spectralReadout {
                if let secondary = readout.secondary {
                    Text("\(readout.primary)  ·  \(secondary)")
                } else {
                    Text(readout.primary)
                }
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Timeline-style channel scrubber: the cube-mean spectrum as a waveform
/// backdrop, a progress fill, and click/drag to scrub. Shared by slice and
/// volume modes (in volume it drives the slice-plane marker).
struct ChannelScrubber: View {
    let profile: [Float]?
    let channel: Int
    let count: Int
    let onScrub: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let frac = count > 1 ? CGFloat(channel) / CGFloat(count - 1) : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)

                Canvas { ctx, size in
                    guard let profile, profile.count > 1 else { return }
                    let finite = profile.filter { $0.isFinite }
                    let lo = finite.min() ?? 0
                    let hi = finite.max() ?? 1
                    let range = hi - lo == 0 ? 1 : hi - lo
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (i, value) in profile.enumerated() {
                        let x = size.width * CGFloat(i) / CGFloat(profile.count - 1)
                        let norm = value.isFinite ? CGFloat((value - lo) / range) : 0
                        path.addLine(to: CGPoint(x: x, y: size.height * (1 - norm)))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.secondary.opacity(0.3)))
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: w * frac)

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: h)
                    .offset(x: w * frac - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard w > 0 else { return }
                    let f = max(0, min(1, value.location.x / w))
                    onScrub(Int((f * CGFloat(max(count - 1, 1))).rounded()))
                }
            )
        }
        .frame(height: 38)
    }
}
