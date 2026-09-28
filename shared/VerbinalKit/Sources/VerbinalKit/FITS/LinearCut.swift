// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The first look at an image or a cube under a linear stretch — the
/// person chose linear (plan 15, decision 2): black a little below the
/// background, white where the brightest percent begins.
///
/// The cut it replaces, median ± 3σ, put the sky at mid-grey and every
/// faint galaxy above sky + 3σ at white, so a JWST deep field looked washed
/// out; a cube windowed p0.1–p99.9 was nearly black under its brightest
/// voxels (QA M5). One rule serves both viewers.
public enum LinearCut {
    /// At most this many values are looked at; the rest are skipped evenly.
    static let maxSamples = 100_000

    /// The cut for `samples` in any order; non-finite values are ignored.
    public static func firstLook(samples: [Float]) -> (lo: Float, hi: Float) {
        let step = max(1, samples.count / maxSamples)
        var finite: [Float] = []
        finite.reserveCapacity(min(samples.count, maxSamples))
        for i in Swift.stride(from: 0, to: samples.count, by: step) where samples[i].isFinite {
            finite.append(samples[i])
        }
        finite.sort()
        return firstLook(sorted: finite)
    }

    /// The cut for finite values sorted ascending.
    public static func firstLook(sorted values: [Float]) -> (lo: Float, hi: Float) {
        guard let first = values.first, let last = values.last else { return (0, 1) }
        let data = withoutFill(values)
        func quantile(_ f: Double) -> Float { data[min(data.count - 1, max(0, Int(f * Double(data.count - 1))))] }

        // The background — the sky, or a cube's empty voxels — without its
        // sources: a robust centre and spread, once more after clipping at 3σ.
        var (centre, spread) = centreAndSpread(data)
        if spread > 0 {
            let kept = data.filter { abs($0 - centre) <= 3 * spread }
            if kept.count > 10 { (centre, spread) = centreAndSpread(kept) }
        }

        var lo = max(data[0], centre - 2 * spread)
        var hi = min(data[data.count - 1], max(quantile(0.99), centre + 5 * spread))
        if !(hi > lo) { (lo, hi) = (quantile(0.01), quantile(0.99)) }
        if !(hi > lo) { (lo, hi) = (first, last) }
        return (lo, hi)
    }

    /// `sorted` without a fill value — the zero border of a mosaic, a blank
    /// level — when one value is a twentieth or more of all of them.
    static func withoutFill(_ sorted: [Float]) -> [Float] {
        var best: (value: Float, count: Int) = (sorted[0], 0)
        var runStart = 0
        for i in 1...sorted.count where i == sorted.count || sorted[i] != sorted[runStart] {
            if i - runStart > best.count { best = (sorted[runStart], i - runStart) }
            runStart = i
        }
        guard best.count * 20 >= sorted.count, best.count < sorted.count else { return sorted }
        return sorted.filter { $0 != best.value }
    }

    /// The median, and the spread as a Gaussian σ from the median absolute deviation.
    static func centreAndSpread(_ sorted: [Float]) -> (centre: Float, spread: Float) {
        let median = sorted[sorted.count / 2]
        var deviations = sorted.map { abs($0 - median) }
        deviations.sort()
        return (median, deviations[deviations.count / 2] * 1.4826)
    }
}
