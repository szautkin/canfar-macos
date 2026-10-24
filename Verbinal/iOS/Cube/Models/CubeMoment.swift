// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Moment 0 — each spaxel's sum over the channels, times the channel width —
/// for "did the line show up" (plan 47 5.5). Built a plane at a time, so
/// memory stays at one plane and the sum.
struct CubeMoment0: Sendable {
    private(set) var sum: [Float]
    private var counts: [Int32]
    private(set) var planes = 0

    init(spaxels: Int) {
        sum = [Float](repeating: 0, count: spaxels)
        counts = [Int32](repeating: 0, count: spaxels)
    }

    /// Adds a channel; its blank (NaN) spaxels add nothing.
    mutating func add(_ plane: [Float]) {
        precondition(plane.count == sum.count, "a plane of the cube")
        for index in plane.indices where plane[index].isFinite {
            sum[index] += plane[index]
            counts[index] += 1
        }
        planes += 1
    }

    /// The map: a spaxel blank in every channel stays blank. `channelWidth` is
    /// the spectral axis's step (CDELT3), its sign dropped; 1 when unknown.
    func map(channelWidth: Double = 1) -> [Float] {
        let width = Float(abs(channelWidth) > 0 ? abs(channelWidth) : 1)
        return sum.indices.map { counts[$0] == 0 ? .nan : sum[$0] * width }
    }
}
