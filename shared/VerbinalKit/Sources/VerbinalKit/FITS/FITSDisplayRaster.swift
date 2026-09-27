// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The picture of an image, as distinct from the image: what the viewer
/// draws, at a size a screen and a GPU can take.
///
/// Every image was drawn at full size. A 20315 × 20475 MegaPipe tile is a
/// 1.6 GB bitmap, remade on every move of a stretch slider, and wider than
/// the 16384 pixels a Metal texture can be — while a screen shows a few
/// million pixels. So only the picture is reduced: the image's own pixels
/// stay whole, and everything that reads a VALUE or a COORDINATE — the
/// readout, the WCS, marks, Go To, an agent's probe — goes on reading them.
public enum FITSDisplayRaster {
    /// At most this many pixels drawn: 256 MB as RGBA.
    public static let maxPixels = 64 * 1024 * 1024
    /// The widest texture Metal is required to take.
    public static let maxSide = 16384

    /// The fraction of full size the picture is drawn at: 1 when it fits as it is.
    public static func scale(width: Int, height: Int, maxPixels: Int = maxPixels, maxSide: Int = maxSide) -> Double {
        guard width > 0, height > 0 else { return 1 }
        let byArea = (Double(maxPixels) / (Double(width) * Double(height))).squareRoot()
        let bySide = Double(maxSide) / Double(max(width, height))
        return min(1, byArea, bySide)
    }

    /// The picture of `pixels` (`width` × `height`, in file order): the
    /// pixels themselves when they fit, otherwise a block average within
    /// the limits.
    ///
    /// An average, not every Nth pixel: a star is often a pixel or two
    /// across, and decimation leaves holes in the sky where sources are. An
    /// average keeps each one, spread over its block — what binning an
    /// astronomical image means. Non-finite pixels are left out of it; a
    /// block with nothing finite stays NaN.
    public static func picture(of pixels: [Float], width: Int, height: Int,
                               maxPixels: Int = maxPixels, maxSide: Int = maxSide) -> (pixels: [Float], width: Int, height: Int) {
        let scale = scale(width: width, height: height, maxPixels: maxPixels, maxSide: maxSide)
        guard scale < 1, pixels.count >= width * height else { return (pixels, width, height) }
        // Floors, after a hair of tolerance (6 × ⅓ is 1.9999999999999998),
        // so neither the area nor a side passes its limit.
        let w = max(1, Int(Double(width) * scale + 1e-6))
        let h = max(1, Int(Double(height) * scale + 1e-6))
        // Each output column covers columns [starts[c], starts[c + 1]).
        let starts = (0...w).map { $0 * width / w }
        var picture = [Float](repeating: .nan, count: w * h)
        pixels.withUnsafeBufferPointer { source in
            picture.withUnsafeMutableBufferPointer { output in
                let out = output.baseAddress!
                let src = source.baseAddress!
                // Rows are independent: each output row reads its own band.
                DispatchQueue.concurrentPerform(iterations: h) { oy in
                    var sums = [Double](repeating: 0, count: w)
                    var counts = [Int](repeating: 0, count: w)
                    for y in (oy * height / h)..<((oy + 1) * height / h) {
                        let row = src + y * width
                        for c in 0..<w {
                            for x in starts[c]..<starts[c + 1] where row[x].isFinite {
                                sums[c] += Double(row[x])
                                counts[c] += 1
                            }
                        }
                    }
                    for c in 0..<w where counts[c] > 0 {
                        out[oy * w + c] = Float(sums[c] / Double(counts[c]))
                    }
                }
            }
        }
        return (picture, w, h)
    }
}
