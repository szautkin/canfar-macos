// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Editable opacity transfer function: control points (value ∈ [0,1] →
/// alpha ∈ [0,1]) the volume renderer samples. Drag points to reshape the curve;
/// the two endpoints are pinned in value and move only in alpha.
struct TransferFunctionEditor: View {
    @Binding var points: [SIMD2<Float>]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let sorted = points.indices.sorted { points[$0].x < points[$1].x }

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)

                // Filled area under the curve.
                Path { path in
                    guard !sorted.isEmpty else { return }
                    path.move(to: CGPoint(x: 0, y: h))
                    for i in sorted {
                        path.addLine(to: viewPoint(points[i], w: w, h: h))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.25))

                // Curve line.
                Path { path in
                    guard let first = sorted.first else { return }
                    path.move(to: viewPoint(points[first], w: w, h: h))
                    for i in sorted.dropFirst() {
                        path.addLine(to: viewPoint(points[i], w: w, h: h))
                    }
                }
                .stroke(Color.accentColor, lineWidth: 1.5)

                // Draggable handles.
                ForEach(points.indices, id: \.self) { index in
                    let isEndpoint = index == minIndex || index == maxIndex
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .position(viewPoint(points[index], w: w, h: h))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    update(index: index, to: value.location, w: w, h: h, lockX: isEndpoint)
                                }
                        )
                }
            }
        }
        .frame(height: 110)
    }

    private var minIndex: Int { points.indices.min { points[$0].x < points[$1].x } ?? 0 }
    private var maxIndex: Int { points.indices.max { points[$0].x < points[$1].x } ?? 0 }

    private func viewPoint(_ p: SIMD2<Float>, w: CGFloat, h: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(p.x) * w, y: h * (1 - CGFloat(p.y)))
    }

    private func update(index: Int, to location: CGPoint, w: CGFloat, h: CGFloat, lockX: Bool) {
        guard w > 0, h > 0 else { return }
        let newAlpha = Float(max(0, min(1, 1 - location.y / h)))
        var newX = points[index].x
        if !lockX {
            newX = Float(max(0, min(1, location.x / w)))
        }
        points[index] = SIMD2(newX, newAlpha)
    }
}
