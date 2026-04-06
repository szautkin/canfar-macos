// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CoreGraphics

/// CPU-based FITS rendering engine.
/// Applies stretch + colormap to raw pixels and produces a CGImage.
/// Metal GPU upgrade path: replace this with a compute shader for sub-ms rendering.
enum FITSRenderEngine {

    /// Render pixel data to a CGImage with the given parameters.
    static func render(
        pixels: [Float],
        width: Int,
        height: Int,
        params: FITSRenderParams
    ) -> CGImage? {
        let count = width * height
        guard count > 0, pixels.count >= count else { return nil }

        let colormap = buildColormap(params.colormap)
        let minCut = params.minCut
        let maxCut = params.maxCut
        let range = maxCut - minCut
        guard range > 0 else { return nil }

        // BGRA8 pixel buffer
        var bitmap = [UInt8](repeating: 0, count: count * 4)

        for y in 0..<height {
            let srcRow = height - 1 - y // Y-flip: FITS origin = bottom-left
            for x in 0..<width {
                let raw = pixels[srcRow * width + x]
                let clamped = min(max((raw - minCut) / range, 0), 1)
                let stretched = applyStretch(clamped, mode: params.stretch)
                let lutIdx = min(Int(stretched * 255), 255)
                let color = colormap[lutIdx]

                let dstIdx = (y * width + x) * 4
                bitmap[dstIdx + 0] = color.r
                bitmap[dstIdx + 1] = color.g
                bitmap[dstIdx + 2] = color.b
                bitmap[dstIdx + 3] = 255
            }
        }

        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        return bitmap.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return nil as CGImage? }
            guard let provider = CGDataProvider(data: Data(bytes: baseAddress, count: bitmap.count) as CFData) else {
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bitsPerPixel,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    // MARK: - Stretch Functions

    private static func applyStretch(_ x: Float, mode: FITSRenderParams.StretchMode) -> Float {
        switch mode {
        case .linear:
            return x
        case .log:
            return log10(1 + 9 * x) / log10(10)
        case .sqrt:
            return sqrtf(x)
        case .squared:
            return x * x
        case .asinh:
            return asinhf(10 * x) / asinhf(10)
        }
    }

    // MARK: - Colormaps (256-entry LUTs)

    private struct RGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private static func buildColormap(_ type: FITSRenderParams.ColormapType) -> [RGB] {
        (0..<256).map { i -> RGB in
            let t = Float(i) / 255.0
            switch type {
            case .grayscale:
                let v = UInt8(t * 255)
                return RGB(r: v, g: v, b: v)
            case .inverted:
                let v = UInt8((1 - t) * 255)
                return RGB(r: v, g: v, b: v)
            case .heat:
                let r = UInt8(min(t * 3, 1) * 255)
                let g = UInt8(max(min((t - 0.33) * 3, 1), 0) * 255)
                let b = UInt8(max(min((t - 0.67) * 3, 1), 0) * 255)
                return RGB(r: r, g: g, b: b)
            case .cool:
                return RGB(r: UInt8(t * 255), g: UInt8((1 - t) * 255), b: 255)
            case .viridis:
                var rv: Float = t * 0.5
                if t > 0.7 { rv += (t - 0.7) * 3.3 }
                let gv: Float = t * 0.8 + 0.1
                var bv: Float = 0.5 - t * 0.5
                if t < 0.3 { bv += t }
                return RGB(
                    r: UInt8(min(max(rv, 0), 1) * 255),
                    g: UInt8(min(max(gv, 0), 1) * 255),
                    b: UInt8(min(max(bv, 0), 1) * 255)
                )
            }
        }
    }
}
