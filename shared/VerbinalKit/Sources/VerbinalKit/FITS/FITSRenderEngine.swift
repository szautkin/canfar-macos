// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CoreGraphics
import Accelerate

/// CPU-based FITS rendering engine.
/// Uses vDSP for vectorized stretch and colormap application.
/// Supports render cancellation for responsive slider interaction.
public enum FITSRenderEngine {

    /// Render pixel data to a CGImage with the given parameters.
    public static func render(
        pixels: [Float],
        width: Int,
        height: Int,
        params: FITSRenderParams
    ) -> CGImage? {
        let (count, countOverflow) = width.multipliedReportingOverflow(by: height)
        guard !countOverflow, count > 0, pixels.count >= count else { return nil }
        let (bitmapSize, bitmapOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !bitmapOverflow else { return nil }
        _ = bitmapSize

        let minCut = params.minCut
        let maxCut = params.maxCut
        let range = maxCut - minCut
        guard range > 0 else { return nil }

        // Step 1: Replace NaN/Inf with 0, then normalize + clamp to [0,1]
        var normalized = [Float](repeating: 0, count: count)
        // Replace NaN/Inf with 0 (common in HST drizzled images for masked regions)
        for i in 0..<count {
            normalized[i] = pixels[i].isFinite ? pixels[i] : 0
        }
        var negMin = -minCut
        vDSP_vsadd(normalized, 1, &negMin, &normalized, 1, vDSP_Length(count))
        var invRange = 1.0 / range
        vDSP_vsmul(normalized, 1, &invRange, &normalized, 1, vDSP_Length(count))
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(normalized, 1, &lo, &hi, &normalized, 1, vDSP_Length(count))

        // Step 2: Apply stretch (vectorized where possible)
        applyStretchInPlace(&normalized, count: count, mode: params.stretch)

        // Step 3: Build colormap and apply
        let colormap = buildColormap(params.colormap)
        var bitmap = [UInt8](repeating: 0, count: count * 4)

        for y in 0..<height {
            let srcRow = height - 1 - y
            for x in 0..<width {
                let val = normalized[srcRow * width + x]
                let lutIdx = val.isFinite ? min(Int(val * 255), 255) : 0
                let color = colormap[max(lutIdx, 0)]
                let dstIdx = (y * width + x) * 4
                bitmap[dstIdx + 0] = color.r
                bitmap[dstIdx + 1] = color.g
                bitmap[dstIdx + 2] = color.b
                bitmap[dstIdx + 3] = 255
            }
        }

        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        return bitmap.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return nil as CGImage? }
            guard let provider = CGDataProvider(data: Data(bytes: baseAddress, count: bitmap.count) as CFData) else {
                return nil
            }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    // MARK: - Vectorized Stretch Functions

    private static func applyStretchInPlace(_ data: inout [Float], count: Int, mode: FITSRenderParams.StretchMode) {
        switch mode {
        case .linear:
            break // already normalized
        case .log:
            // log10(1 + 9*x) / log10(10) = log10(1 + 9*x)
            var nine: Float = 9
            var one: Float = 1
            vDSP_vsmsa(data, 1, &nine, &one, &data, 1, vDSP_Length(count)) // data = 9*data + 1
            var n = Int32(count)
            vvlog10f(&data, data, &n) // data = log10(data)
        case .sqrt:
            var n = Int32(count)
            vvsqrtf(&data, data, &n)
        case .squared:
            vDSP_vsq(data, 1, &data, 1, vDSP_Length(count))
        case .asinh:
            // asinh(10*x) / asinh(10)
            var ten: Float = 10
            vDSP_vsmul(data, 1, &ten, &data, 1, vDSP_Length(count)) // data = 10*data
            for i in 0..<count { data[i] = asinhf(data[i]) } // no vDSP asinh
            var divisor = asinhf(10)
            vDSP_vsdiv(data, 1, &divisor, &data, 1, vDSP_Length(count))
        }
    }

    // MARK: - Colormaps (256-entry LUTs)

    private struct RGB {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private static func buildColormap(_ type: FITSRenderParams.ColormapType) -> [RGB] {
        (0..<256).map { i in
            let c = colormapColor(Float(i) / 255.0, type)
            return RGB(r: c.0, g: c.1, b: c.2)
        }
    }

    /// 256-entry RGBA colormap LUT (4 bytes/entry, alpha = 255). Public so the
    /// cube viewer's Metal volume renderer can build its colormap texture from
    /// the *same* ramps the 2D/slice renderer uses — one source of truth, so
    /// slice and volume modes always agree on color.
    public static func colormapRGBA(_ type: FITSRenderParams.ColormapType) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let c = colormapColor(Float(i) / 255.0, type)
            out[i * 4 + 0] = c.0
            out[i * 4 + 1] = c.1
            out[i * 4 + 2] = c.2
            out[i * 4 + 3] = 255
        }
        return out
    }

    /// Single source of truth for the colormap ramps, shared by `buildColormap`
    /// (CPU slice render) and `colormapRGBA` (GPU volume texture).
    private static func colormapColor(_ t: Float, _ type: FITSRenderParams.ColormapType) -> (UInt8, UInt8, UInt8) {
        switch type {
        case .grayscale:
            let v = UInt8(t * 255)
            return (v, v, v)
        case .inverted:
            let v = UInt8((1 - t) * 255)
            return (v, v, v)
        case .heat:
            let r = UInt8(min(t * 3, 1) * 255)
            let g = UInt8(max(min((t - 0.33) * 3, 1), 0) * 255)
            let b = UInt8(max(min((t - 0.67) * 3, 1), 0) * 255)
            return (r, g, b)
        case .cool:
            return (UInt8(t * 255), UInt8((1 - t) * 255), 255)
        case .viridis:
            var rv: Float = t * 0.5
            if t > 0.7 { rv += (t - 0.7) * 3.3 }
            let gv: Float = t * 0.8 + 0.1
            var bv: Float = 0.5 - t * 0.5
            if t < 0.3 { bv += t }
            return (
                UInt8(min(max(rv, 0), 1) * 255),
                UInt8(min(max(gv, 0), 1) * 255),
                UInt8(min(max(bv, 0), 1) * 255)
            )
        case .inferno:
            return interpolateAnchors(infernoAnchors, t)
        case .magma:
            return interpolateAnchors(magmaAnchors, t)
        case .plasma:
            return interpolateAnchors(plasmaAnchors, t)
        }
    }

    /// Linear interpolation over a compact RGB anchor table (values in 0…1).
    private static func interpolateAnchors(_ anchors: [SIMD3<Float>], _ t: Float) -> (UInt8, UInt8, UInt8) {
        let n = anchors.count
        guard n > 1 else { return (0, 0, 0) }
        let x = max(0, min(1, t)) * Float(n - 1)
        let i = min(Int(x), n - 2)
        let c = anchors[i] + (anchors[i + 1] - anchors[i]) * (x - Float(i))
        return (UInt8(max(0, min(1, c.x)) * 255), UInt8(max(0, min(1, c.y)) * 255), UInt8(max(0, min(1, c.z)) * 255))
    }

    // Compact matplotlib-style anchor tables (9 stops), linearly interpolated.
    private static let infernoAnchors: [SIMD3<Float>] = [
        SIMD3(0.001, 0.000, 0.014), SIMD3(0.088, 0.044, 0.224), SIMD3(0.258, 0.039, 0.406),
        SIMD3(0.417, 0.091, 0.433), SIMD3(0.578, 0.148, 0.404), SIMD3(0.736, 0.215, 0.330),
        SIMD3(0.865, 0.317, 0.226), SIMD3(0.955, 0.485, 0.092), SIMD3(0.988, 0.998, 0.645),
    ]
    private static let magmaAnchors: [SIMD3<Float>] = [
        SIMD3(0.001, 0.000, 0.014), SIMD3(0.078, 0.043, 0.206), SIMD3(0.232, 0.059, 0.438),
        SIMD3(0.390, 0.100, 0.502), SIMD3(0.550, 0.161, 0.506), SIMD3(0.716, 0.215, 0.475),
        SIMD3(0.868, 0.288, 0.409), SIMD3(0.967, 0.440, 0.360), SIMD3(0.987, 0.991, 0.749),
    ]
    private static let plasmaAnchors: [SIMD3<Float>] = [
        SIMD3(0.050, 0.030, 0.528), SIMD3(0.254, 0.013, 0.615), SIMD3(0.417, 0.000, 0.658),
        SIMD3(0.562, 0.052, 0.641), SIMD3(0.692, 0.165, 0.564), SIMD3(0.798, 0.280, 0.470),
        SIMD3(0.881, 0.392, 0.383), SIMD3(0.949, 0.518, 0.295), SIMD3(0.940, 0.975, 0.131),
    ]
}
