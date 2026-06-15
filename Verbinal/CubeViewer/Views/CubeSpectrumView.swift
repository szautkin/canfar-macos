// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Lightweight spectrum plot: value through (x, y) across all channels, with the
/// active channel marked. Tapping the plot jumps to that channel.
struct CubeSpectrumView: View {
    let spectrum: [Float]
    let channel: Int
    let onPick: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let finite = spectrum.filter { $0.isFinite }
            let lo = finite.min() ?? 0
            let hi = finite.max() ?? 1
            let range = hi - lo == 0 ? 1 : hi - lo
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Curve
                Path { path in
                    guard spectrum.count > 1 else { return }
                    var started = false
                    for (i, value) in spectrum.enumerated() {
                        guard value.isFinite else { started = false; continue }
                        let x = w * CGFloat(i) / CGFloat(spectrum.count - 1)
                        let y = h * (1 - CGFloat((value - lo) / range))
                        if started {
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.move(to: CGPoint(x: x, y: y))
                            started = true
                        }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)

                // Active-channel marker
                if spectrum.count > 1 {
                    let cx = w * CGFloat(channel) / CGFloat(spectrum.count - 1)
                    Path { p in
                        p.move(to: CGPoint(x: cx, y: 0))
                        p.addLine(to: CGPoint(x: cx, y: h))
                    }
                    .stroke(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard spectrum.count > 1, w > 0 else { return }
                let fraction = max(0, min(1, location.x / w))
                onPick(Int((fraction * CGFloat(spectrum.count - 1)).rounded()))
            }
        }
    }
}
