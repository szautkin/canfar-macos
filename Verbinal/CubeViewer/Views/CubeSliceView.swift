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
    @State private var hoverLocation: CGPoint?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            coordinateBar
            timeline
        }
    }

    // MARK: Image

    private var imageArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = model.sliceImage {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(pan)
                } else if model.isRendering {
                    ProgressView()
                }

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
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { zoom = max(1, min(lastZoom * $0, 20)) }
                    .onEnded { _ in lastZoom = zoom }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { pan = CGSize(width: lastPan.width + $0.translation.width, height: lastPan.height + $0.translation.height) }
                    .onEnded { _ in lastPan = pan }
            )
            .onTapGesture(count: 2) { resetView() }
            .onTapGesture(coordinateSpace: .local) { location in
                if let (x, y) = imagePixel(at: fitLocation(location, in: geo.size), in: geo.size) {
                    Task { await model.probe(x: Int(x.rounded()), y: Int(y.rounded())) }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    if let (x, y) = imagePixel(at: fitLocation(location, in: geo.size), in: geo.size) {
                        Task { await model.updateCursor(x: x, y: y) }
                    }
                case .ended:
                    hoverLocation = nil
                    model.clearCursor()
                }
            }
            .onChange(of: model.fileName) { _, _ in resetView() }
        }
    }

    private func resetView() {
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
    }

    /// Undo the zoom/pan transform (applied around the view center) so a view-space
    /// location maps back to the aspect-fit image space `imagePixel` expects.
    private func fitLocation(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: cx + (p.x - pan.width - cx) / zoom, y: cy + (p.y - pan.height - cy) / zoom)
    }

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

    // MARK: Timeline (play + waveform scrubber)

    private var timeline: some View {
        HStack(spacing: 12) {
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(model.isPlaying ? "Pause (Space)" : "Play through channels (Space)")
            .disabled(model.nz <= 1)

            Button { model.stepChannel(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(model.channel <= 0)

            ChannelScrubber(
                profile: model.channelProfile,
                channel: model.channel,
                count: model.nz,
                onScrub: { model.setChannel($0) }
            )

            Button { model.stepChannel(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(model.channel >= model.nz - 1)

            Text("\(model.channel + 1) / \(model.nz)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Hit-testing

    /// Map a view-space location to a 0-based FITS pixel (x, y), flipping Y so the
    /// readout matches FITS convention (y increases upward). Returns nil outside
    /// the aspect-fit image rect.
    private func imagePixel(at location: CGPoint, in size: CGSize) -> (Double, Double)? {
        guard model.nx > 0, model.ny > 0 else { return nil }
        let iw = CGFloat(model.nx), ih = CGFloat(model.ny)
        let scale = min(size.width / iw, size.height / ih)
        guard scale > 0 else { return nil }
        let dw = iw * scale, dh = ih * scale
        let ox = (size.width - dw) / 2, oy = (size.height - dh) / 2
        guard location.x >= ox, location.x <= ox + dw, location.y >= oy, location.y <= oy + dh else { return nil }
        let px = Double((location.x - ox) / scale)
        let pyTop = Double((location.y - oy) / scale)
        let fitsX = min(max(px, 0), Double(model.nx - 1))
        let fitsY = min(max(Double(model.ny) - pyTop, 0), Double(model.ny - 1))
        return (fitsX, fitsY)
    }
}

/// Timeline-style channel scrubber: the cube-mean spectrum as a waveform
/// backdrop, a progress fill, and click/drag to scrub.
private struct ChannelScrubber: View {
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
