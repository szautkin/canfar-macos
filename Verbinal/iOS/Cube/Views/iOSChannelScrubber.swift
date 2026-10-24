// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// The channels under the thumb (plan 47 5.2): the cube's mean spectrum drawn
/// behind a wide scrubber, a tick for each channel crossed and a firmer one on
/// a peak, and where the channel is on the spectral axis.
struct iOSChannelScrubber: View {
    var model: CubeViewerModel

    @State private var dragging = false

    private var lastChannel: Int { max(model.nz - 1, 0) }

    /// Channels whose mean is higher than both neighbours'.
    private var peaks: Set<Int> {
        guard let profile = model.channelProfile, profile.count > 2 else { return [] }
        return Set((1..<(profile.count - 1)).filter {
            profile[$0].isFinite && profile[$0] > profile[$0 - 1] && profile[$0] > profile[$0 + 1]
        })
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    model.togglePlayback()
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.bordered)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.spectralReadout?.primary ?? String(localized: "Channel \(model.channel)"))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    if let secondary = model.spectralReadout?.secondary {
                        Text(verbatim: secondary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(verbatim: "\(model.channel) / \(lastChannel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let width = geometry.size.width, height = geometry.size.height
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                    waveform(width: width, height: height)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: height)
                        .offset(x: x(of: model.channel, width) - 1.5)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: dragging ? 26 : 20, height: dragging ? 26 : 20)
                        .offset(x: x(of: model.channel, width) - (dragging ? 13 : 10))
                        .shadow(radius: 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                            model.setChannel(Int((fraction * CGFloat(lastChannel)).rounded()))
                        }
                        .onEnded { _ in dragging = false }
                )
            }
            .frame(height: 44)
            .sensoryFeedback(.selection, trigger: model.channel) { _, channel in !peaks.contains(channel) }
            .sensoryFeedback(.impact(weight: .medium), trigger: model.channel) { _, channel in peaks.contains(channel) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Channel"))
            .accessibilityValue(Text(verbatim: model.spectralReadout?.primary ?? "\(model.channel)"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.stepChannel(1)
                case .decrement: model.stepChannel(-1)
                @unknown default: break
                }
            }
        }
    }

    private func x(of channel: Int, _ width: CGFloat) -> CGFloat {
        lastChannel > 0 ? CGFloat(channel) / CGFloat(lastChannel) * width : 0
    }

    /// The cube's mean spectrum, scaled to the strip; blank channels leave gaps.
    @ViewBuilder
    private func waveform(width: CGFloat, height: CGFloat) -> some View {
        if let profile = model.channelProfile, profile.count > 1 {
            let finite = profile.filter(\.isFinite)
            if let lo = finite.min(), let hi = finite.max(), hi > lo {
                Path { path in
                    var drawing = false
                    for (index, value) in profile.enumerated() {
                        guard value.isFinite else { drawing = false; continue }
                        let point = CGPoint(x: CGFloat(index) / CGFloat(profile.count - 1) * width,
                                            y: height - 4 - CGFloat((value - lo) / (hi - lo)) * (height - 8))
                        if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
                    }
                }
                .stroke(Color.secondary, lineWidth: 1.5)
            }
        }
    }
}
