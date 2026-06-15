// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Slice mode: the active channel rendered at native resolution (via the shared
/// `FITSRenderEngine`), a channel scrubber, a WCS + spectral coordinate bar, and
/// click-to-probe spectrum.
struct CubeSliceView: View {
    let model: CubeViewerModel

    var body: some View {
        VStack(spacing: 0) {
            imageArea
            coordinateBar
            channelScrubber
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
                } else if model.isRendering {
                    ProgressView()
                }

                if model.probePoint != nil, let spectrum = model.probeSpectrum {
                    spectrumOverlay(spectrum)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if let (x, y) = imagePixel(at: location, in: geo.size) {
                        Task { await model.updateCursor(x: x, y: y) }
                    }
                case .ended:
                    model.clearCursor()
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                if let (x, y) = imagePixel(at: location, in: geo.size) {
                    Task { await model.probe(x: Int(x.rounded()), y: Int(y.rounded())) }
                }
            }
        }
    }

    @ViewBuilder
    private func spectrumOverlay(_ spectrum: [Float]) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let point = model.probePoint {
                        Text("Spectrum @ (\(point.x), \(point.y))")
                            .font(.caption.bold())
                    }
                    Spacer()
                    Button {
                        model.clearProbe()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                CubeSpectrumView(spectrum: spectrum, channel: model.channel) { model.setChannel($0) }
                    .frame(height: 90)
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

    // MARK: Channel scrubber

    private var channelScrubber: some View {
        HStack(spacing: 12) {
            Button { model.stepChannel(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(model.channel <= 0)

            Slider(
                value: Binding(
                    get: { Double(model.channel) },
                    set: { model.setChannel(Int($0.rounded())) }
                ),
                in: 0...Double(max(model.nz - 1, 1))
            )

            Button { model.stepChannel(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(model.channel >= model.nz - 1)

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
